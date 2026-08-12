require 'webrick'
require 'cgi'
require 'json'

module Ore
	class Interpreter
		attr_accessor :input, :lexer, :parser, :load_standard_library, :stack, :route_functions_by_route_name, :servers, :dom_onclick_function_handlers, :dom_input_elements, :cached_expressions_by_filepath, :cached_source_by_filename, :last_output, :current_source_file

		def initialize
			@cached_expressions_by_filepath = {} # {filepath: [Ore::Expression]}
			@cached_source_by_filename      = {} # {filepath: String}
			@dom_input_elements             = {} # {element_hash: Ore::Instance} for inputs/textareas
			@dom_onclick_function_handlers  = {} # {handler_hash: Ore::Func}
			@route_functions_by_route_name  = {} # {route: Ore::Route}

			@load_standard_library = true
			@input                 = [] # [Ore::Expression]
			@stack                 = [] # [Ore::Scope]
			@servers               = [] # [Ore::Server]

			@lexer  = Lexer.new
			@parser = Parser.new
		end

		def run source_code
			top_level_source_file = current_source_file

			if @stack.empty?
				# todo; Global should be created by interping ore/global.ore, which is what I want to rename ore/preload.ore to
				global = Global.new
				if load_standard_library
					load_file_into_scope STANDARD_LIBRARY_PATH, global
				end
				@stack << global
			end
			@lexer.source_file    = top_level_source_file
			@lexer.input          = source_code
			@parser.input         = @lexer.output.reject do |lexeme|
				%I(comment).include? lexeme.type # The interpreter doesn't care about these
			end
			@input                = @parser.output # Expressions

			@last_output = output
			if servers.any? { |server| server.webrick_server&.status == :Running }
				loop_servers
			else
				@last_output
			end
		end

		def output
			checker = Type_Checker.new input
			raise checker.output if checker.output

			input.each.inject(nil) do |_, expr|
				interpret expr
			end
		end

		def loop_servers
			begin
				keep_running = true

				trap_fn = Proc.new do
					puts Ore::Ascii.dim "Shutting down..."
					keep_running = false
					puts "\n\s\s(V) (;,,;) (V)"
					Thread.main.exit
				end
				Signal.trap 'INT', trap_fn
				Signal.trap 'TERM', trap_fn

				while keep_running
					@servers.each do |server|
						puts "Ore Server `#{server.name}` started at http://localhost:#{server.port}"
						server.server_thread&.join
					end
				end
			ensure
				@servers.each { |s| stop_server s }
			end
		end

		# Preserves its @input, interprets given file, then restores its @input.
		# @return The output of the interpreted file
		def load_file_into_scope filepath, into_scope
			filepath.insert(-1, '.ore') unless filepath.end_with? '.ore'

			resolved_path = if filepath.start_with? 'ore/'
				File.join ROOT_PATH, filepath
			else
				File.expand_path filepath
			end

			push_scope into_scope

			unless @cached_expressions_by_filepath[resolved_path]
				code = File.read resolved_path
				register_source resolved_path, code
				@lexer.source_file                             = resolved_path
				@lexer.input                                   = code
				@parser.input                                  = @lexer.output.reject do |lexeme|
					%I(comment).include? lexeme.type
				end
				@cached_expressions_by_filepath[resolved_path] = @parser.output
			end

			saved  = @input
			@input = @cached_expressions_by_filepath[resolved_path]
			result = output # note: Okay to call #output directly here
			@input = saved

			pop_scope
			result
		end

		def push_scope scope
			scope ||= stack.last
			stack << scope
		end

		def pop_scope
			if stack.length == 1
				stack.last
			else
				stack.pop
			end
		end

		def push_then_pop scope
			raise "Attempting to push `nil` value as scope" if scope == nil
			push_scope scope
			yield scope if block_given?
			pop_scope
		end

		def register_source filepath, source_code
			resolved                            = filepath ? File.expand_path(filepath) : '<inline>'
			cached_source_by_filename[resolved] = source_code.lines.map(&:chomp)
			@current_source_file                = resolved
		end

		def add_onclick_handler handler
			key                                = handler.hash
			dom_onclick_function_handlers[key] = handler
			key
		end

		def add_input_element instance
			key                     = instance.hash
			dom_input_elements[key] = instance
			key
		end

		def scope_for_identifier expr
			unless expr.is_a? Ore::Identifier_Expr
				return stack.last
			end

			case expr.scope_operator&.value
			when '~/' # global
				stack.first
			when '../' # underlying type within context, aka accessing a static declaration
				stack.reverse_each.find do |scope|
					scope.instance_of? Ore::Type
				end
			when './' # instance within context, aka self, this, etc
				stack.reverse_each.find do |scope|
					scope.is_a? Ore::Instance
				end
			else
				# If no scope operator, search through all scopes to find the identifier
				found_scope = nil
				stack.reverse_each do |scope|
					if scope.has?(expr.value) || scope.respond_to?("proxy_#{expr.value}")
						found_scope = scope
						break
					elsif scope.is_a?(Ore::Instance) && scope.enclosing_scope&.has?(expr.value)
						# Method exists on the Type - return the instance as the scope so lookups happen in instance context
						found_scope = scope
						break
					end
				end
				found_scope
			end
		end

		def maybe_instance expr
			# todo, when String and so on, because everything needs to be some type of scope to live inside the runtime. Every object in Ore::Scope.declarations{} is either a primitive like String, Integer, Float, or they're an instanced version like Ore::Number.
			case expr
			when Integer, Float
				# Ore::Number_Expr is already handled in #interpret but this is short-circuiting that for cases like 1.something where we have to make sure the 1 is no longer a numeric literal, but instead a runtime object version of the number 1.
				number             = Ore::Number.new expr
				number.type        = Ore.type_of_number_expr expr
				number.numerator   = expr
				number.denominator = 1

				finish_intrinsic_instance number, 'Number'
			when ::String
				finish_intrinsic_instance Ore::String.new(expr), 'String'
			when ::Array
				finish_intrinsic_instance Ore::Array.new(expr), 'Array'
			when ::Hash
				finish_intrinsic_instance Ore::Dictionary.new(expr), 'Dictionary'
			when nil
				nil_instance = Ore::Nil.shared
				link_instance_to_type nil_instance, 'Nil'
				nil_instance
			when true
				finish_intrinsic_instance Ore::Bool.truthy, 'Bool'
			when false
				finish_intrinsic_instance Ore::Bool.falsy, 'Bool'
			else
				expr
			end
		end

		def finish_intrinsic_instance instance, type_name
			instance.name = type_name
			link_instance_to_type instance, type_name
			instance.types = instance.enclosing_scope ? instance.enclosing_scope.types : Set[type_name]
			instance
		end

		def link_instance_to_type instance, type_name
			global_scope = stack.first
			if global_scope.has? type_name
				instance.enclosing_scope = global_scope[type_name]
			end
		end

		def track_static_declaration scope, ident_expr
			return unless ident_expr.is_a?(Ore::Identifier_Expr) && ident_expr.scope_operator&.value == '../'
			scope.static_declarations ||= Set.new
			scope.static_declarations.add ident_expr.value.to_s
		end

		def check_dot_access_permissions! scope, ident, expr
			binding = Ore.binding_of_ident scope, ident
			privacy = Ore.privacy_of_ident ident

			case scope
			when Ore::Instance
				if privacy == :private && stack.last != scope
					raise Ore::Cannot_Call_Private_Instance_Member.new(expr, self)
				end
			when Ore::Type
				if binding == :instance
					# todo: This does not print the correct code location, here is a paste of the output:
					#       Cannot_Call_Instance_Member_On_Type
					#       :1:1
					raise Ore::Cannot_Call_Instance_Member_On_Type.new(expr, self)
				elsif privacy == :private
					raise Ore::Cannot_Call_Private_Static_Member_On_Type.new(expr, self)
				end
			end
		end

		def find_ruby_class_for_type type
			type.types.to_a.reverse.each do |type_name|
				ore_name = "Ore::#{type_name}"
				next unless Object.const_defined? ore_name
				k = Object.const_get ore_name
				return k if k.is_a?(Class) && k < Ore::Instance && k != Ore::Instance
			end
			nil
		end

		def truthy? value
			return false if value.nil? || false == value
			return false if (value.is_a?(::Integer) || value.is_a?(::Float)) && value.zero?
			true
		end

		def type_name_to_string value
			case value
			when Ore::Number then 'Number'
			when Integer, Float then 'Number'
			when Ore::String then 'String'
			when Ore::Array then 'Array'
			when Ore::Dictionary then 'Dictionary'
			when Ore::Bool then 'Bool'
			when Ore::Instance then value.types.first
			when Ore::Type then value.name
			# todo: Why are these here? Excluding the else clause
			when true, false then 'Bool'
			when ::String then 'String'
			when ::Array then 'Array'
			when ::Hash then 'Dictionary'
			else nil
			end
		end

		def composed_types_for value
			case value
			when Ore::Number, Ore::String, Ore::Array, Ore::Dictionary, Ore::Bool
				composed_types_by_name type_name_to_string(value)
			when Ore::Type
				value.types
			else
				composed_types_by_name type_name_to_string(value)
			end
		end

		def composed_types_by_name name
			return Set.new unless name
			global = stack.first
			global.has?(name) ? global[name].types : Set[name]
		end

		# If `name` is already an Ore::Func_Signature, return it as-is (an inline signature has no name to look up). Otherwise, if it's bound to one anywhere on the stack, return that. Otherwise nil — meaning `name` is an ordinary nominal type name (e.g. 'Number').
		def resolve_func_signature name
			return name if name.is_a? Ore::Func_Signature
			return nil unless name
			found = stack.reverse_each.find { |scope| scope.has? name }
			value = found&.get(name)
			value.is_a?(Ore::Func_Signature) ? value : nil
		end

		# @param expr [Ore::Func_Signature_Expr]
		def build_func_signature expr
			param_types = expr.params.map { |param| param.type&.value }
			Ore::Func_Signature.new param_types, expr.type&.value
		end

		# Readable description of a value's shape for Type_Contract_Violation messages — a func-like value's param/return types if it has them, otherwise its plain type name.
		def describe_value_shape value
			if value.respond_to? :func_signature
				value.func_signature.to_s
			else
				type_name_to_string(value) || 'unknown'
			end
		end

		def start_server server
			ready = Queue.new

			webrick = WEBrick::HTTPServer.new Port:          server.port,
			                                  Logger:        WEBrick::Log.new("/dev/null"),
			                                  AccessLog:     [],
			                                  StartCallback: -> { ready << true }

			webrick.mount_proc '/onclick/' do |req, res|
				puts Ore::Ascii.dim "#{'DOM'.rjust(7, ' ')} #{req.path}"
				handle_request server, req, res
			end

			webrick.mount_proc '' do |req, res|
				handle_request server, req, res
			end

			server.webrick_server = webrick
			server.server_thread  = Thread.new do
				webrick.start
			rescue => e
				ready << e
			end

			# Thread.new returns before the new thread has run at all, so reading .status
			# right after this would race WEBrick's own startup and almost always see :Stop.
			# Block until StartCallback actually fires (or the thread dies trying) instead.
			result = ready.pop
			raise result if result.is_a? Exception

			server.server_thread
		end

		def stop_server server
			server.webrick_server&.shutdown
			Thread.kill server.server_thread if server.server_thread
		end

		def handle_request server, request, response
			path_string  = request.path
			query_string = request.query_string
			http_method  = request.request_method.downcase
			path_parts   = request.path.split('/').reject { _1.empty? }
			body_hash    = CGI.parse(request.body || "").transform_values(&:first)
			headers_hash = request.header.to_h

			req_info = Ascii.dim ""
			unless body_hash.empty?
				req_info = req_info.prepend Ascii.green
			end
			req_info << Ascii.dim(http_method.upcase.rjust(7, " "))
			req_info << " "
			req_info << Ascii.reset(path_string.gsub("/", "#{Ascii.dim('/')}#{Ascii.reset}"))
			unless body_hash.empty?
				req_info << " #{Ascii.dim body_hash}"
			end
			puts req_info

			if path_string.start_with?("/onclick/")
				object_id = path_parts.last.to_i
				handler   = dom_onclick_function_handlers[object_id]
				if handler
					begin
						if request.body && !request.body.empty?
							json_body = JSON.parse request.body rescue {}
							inputs = json_body['inputs'] || {}
							inputs.each do |element_id, value|
								input_instance = dom_input_elements[element_id.to_i]
								input_instance.declare 'value', value if input_instance
							end
						end

						route             = Ore::Route.new
						route.handler     = handler
						route.param_names = []

						req = build_ore_request path_string, http_method, body_hash, parse_query_string(query_string), {}, headers_hash
						res = build_ore_response response

						interp_route_body route, req, res

						component = handler.enclosing_scope
						if component.is_a?(Ore::Instance) && component.declarations['render']
							new_html = render_dom_to_html component
							html_id  = component.declarations['html_id']

							response.status             = 200
							response['Content-Type']    = 'text/html'
							response['X-Ore-Target-Id'] = html_id if html_id
							response.body               = new_html
							return
						end
					rescue => e
						warn "\n[Ore Onclick Error] #{e.class}: #{e.message}"
						warn e.backtrace.first(10).map { |line| "  #{line}" }.join("\n")
						warn ""

						plain_message   = e.message.gsub(/\e\[\d+(?:;\d+)*m/, '')
						response.status = 500
						response.body   = "Internal Server Error\n#{plain_message}"
						return
					end
				end
			end

			if cookie = request.cookies.find { _1.name == BROWSER_VIEW_SIZE }
				parts = cookie.value.split 'x'
				size  = { width: parts[0].to_i, height: parts[1].to_i }
				stack.last.declare BROWSER_VIEW_SIZE, size
			end

			route_function = match_route http_method, path_parts, server.routes

			if route_function
				url_params   = extract_url_params path_parts, route_function
				query_params = parse_query_string query_string

				req = build_ore_request path_string, http_method, body_hash, query_params, url_params, headers_hash

				begin
					res    = build_ore_response response
					result = interp_route_body route_function, req, res, url_params, server_instance: server

					response.status = res.declarations['status']
					response.body   = res.declarations['body']
					res.declarations['headers'].each { |k, v| response.header[k] = v }

					if response.body.to_s =~ /<html|<body|<head/i
						response.body.prepend "<!DOCTYPE html>"

						dom_js     = File.read 'src/runtime/dom.js'
						script_tag = "<script>#{dom_js}</script>"

						body_str = response.body.to_s
						if body_str.include?('<head>')
							response.body = body_str.sub('<head>', '<head>' + script_tag)
						elsif body_str.include?('<body>')
							response.body = body_str.sub('<body>', '<body>' + script_tag)
						else
							response.body = script_tag + body_str
						end
					end

					result

				rescue WEBrick::HTTPStatus::Status => e
					raise e

				rescue => e
					warn "\n[Ore Server Error] #{e.class}: #{e.message}"
					warn e.backtrace.first(10).map { |line| "  #{line}" }.join("\n")
					warn ""

					plain_message   = e.message.gsub(/\e\[\d+(?:;\d+)*m/, '')
					plain_backtrace = e.backtrace.map { |line| line.gsub(/\e\[\d+(?:;\d+)*m/, '') }

					response.status = 500
					response.body   = <<~HTML
					    <h1>500 Internal Server Error</h1>
					    <h2>#{e.class}</h2>
					    <pre>#{plain_message}</pre>
					    <h3>Backtrace</h3>
					    <pre>#{plain_backtrace.join("\n")}</pre>
					HTML
					response.header['Content-Type'] = 'text/html; charset=utf-8'
				end
			else
				response.status = 404
				response.body   = <<~HTML
				    <h1>404 Not Found</h1>
				    <p>No route matches #{http_method.upcase} #{path_string}</p>
				    <hr>
				    <h3>Available Routes:</h3>
				    <ul>
				    	#{server.routes.values.map { |r| "<li>#{r.http_method.value.upcase} /#{r.path}</li>" }.join("\n")}
				    </ul>
				HTML
				response.header['Content-Type'] = 'text/html; charset=utf-8'
			end
		end

		def match_route http_method, path_parts, routes
			routes.values.find do |route|
				next unless route.http_method.value == http_method
				next unless route.parts.count == path_parts.count

				path_parts.zip(route.parts).all? do |req_part, route_part|
					(req_part == route_part) || (route_part.start_with?(':'))
				end
			end
		end

		def extract_url_params path_parts, route
			url_params = {}
			path_parts.zip(route.parts).each do |req_part, route_part|
				if route_part.start_with? ':'
					param_name                    = route_part[1..-1]
					url_params[param_name]        = req_part
					url_params[param_name.to_sym] = req_part
				end
			end
			url_params
		end

		def parse_query_string query_string
			query_params = {}
			if query_string
				query_string.split('&').each do |pair|
					key, value               = pair.split '=', 2
					query_params[key]        = CGI.unescape(value || '')
					query_params[key.to_sym] = CGI.unescape(value || '')
				end
			end
			query_params
		end

		def build_ore_request path_string, http_method, body_hash, query_params, url_params, headers_hash
			req          = Ore::Request.new
			body_dict    = Ore::Dictionary.new body_hash
			query_dict   = Ore::Dictionary.new query_params
			params_dict  = Ore::Dictionary.new url_params
			headers_dict = Ore::Dictionary.new headers_hash
			link_instance_to_type req, 'Request'
			link_instance_to_type body_dict, 'Dictionary'
			link_instance_to_type query_dict, 'Dictionary'
			link_instance_to_type params_dict, 'Dictionary'
			link_instance_to_type headers_dict, 'Dictionary'
			req.declarations['path']              = path_string
			req.declarations['method']            = http_method
			req.declarations['query']             = query_dict
			req.declarations['params']            = params_dict
			req.declarations['headers']           = headers_dict
			req.declarations['body']              = body_dict
			req.declarations['body'].declarations = body_hash
			req
		end

		def build_ore_response webrick_response
			res                                  = Ore::Response.new
			res.webrick_response                 = webrick_response
			res.declarations['webrick_response'] = webrick_response
			res.declarations['status']           = 200
			res.declarations['headers']          = {}
			res.declarations['body']             = ''
			link_instance_to_type res, 'Response'
			res
		end

		def collect_routes_from_instance instance
			collected_routes = {}

			# This iterates composed types to find any
			instance.types.each do |type_name|
				composed_type = stack.first.get type_name
				next unless composed_type && composed_type.respond_to?(:routes) && composed_type.routes

				# Merge routes from this type
				composed_type.routes.each do |key, route|
					collected_routes[key] ||= route
				end
			end

			collected_routes
		end

		def render_dom_to_html dom_instance
			render = dom_instance.declarations['render']

			inner_html = if render
				call_expr           = Ore::Call_Expr.new
				call_expr.receiver  = render
				call_expr.arguments = []

				render_result = interp_func_body render, call_expr

				"".tap do |html|
					if render_result.is_a? ::String
						html << render_result

					elsif render_result.is_a? Ore::Array
						render_result.values.each do |child|
							if child.is_a? ::String
								html << child
							elsif child.is_a?(Ore::Instance) && child.types.include?('Dom')
								html << render_dom_to_html(child)
							end
						end

					elsif render_result.is_a?(Ore::Instance) && render_result.types.include?('Dom')
						html << render_dom_to_html(render_result)

					end
				end
			end

			renderer = Ore::Dom_Renderer.new dom_instance, inner_html

			if renderer.onclick_expr
				add_onclick_handler renderer.onclick_expr
			end

			if renderer.is_input_element?
				add_input_element dom_instance
			end

			renderer.to_html_string
		end

		def interp_identifier expr
			if expr.directive
				# todo: Why is this not handled by Parser#complete_expression?
				dir_expr      = Ore::Directive_Expr.new
				dir_expr.name = expr
				return interp_directive dir_expr
			end

			scope = case expr.value
			when 'nil'
				return nil
			when 'true'
				# todo, return Ore::Bool.truthy
				return true
			when 'false'
				# todo, return Ore::Bool.falsy
				return false
			else
				scope_for_identifier expr
			end

			value = if scope.is_a? ::Array
				found = scope.reverse_each.find do |scope|
					scope.has? expr.value
				end

				if found && found.has?(expr.value)
					found[expr.value]
				else
					raise Ore::Undeclared_Identifier.new(expr, self)
				end
			elsif scope
				# note: Delegate ruby calls automatically
				proxy_method = "proxy_#{expr.value}"
				if scope.has?(expr.value) && !scope.respond_to?(proxy_method)
					result = scope.get expr.value
					# If the result is a function, duplicate it and set its enclosing_scope to the current scope. This ensures composed types (like `Thing | Record`) have functions that reference the correct type
					if result.is_a? Ore::Func
						func                 = result.dup
						func.enclosing_scope = scope
						return func
					end
					result
				elsif scope.respond_to? proxy_method
					# Prefer the instance's own owning Type first -- for a structured variant
					# (e.g. `Array<Web_Server>`) this is a distinct Type from the plain
					# global one, and holds the actual override. Only fall back to a blind
					# by-name search of the stack (which only ever finds the plain global
					# type, e.g. plain "Array") when the instance isn't linked to a Type
					# that declares this method itself.
					type_def       = if scope.enclosing_scope.is_a?(Ore::Type) && scope.enclosing_scope.has?(expr.value)
						scope.enclosing_scope
					else
						type_name  = scope.class.name.split('::').last
						type_scope = stack.reverse_each.find { |s| s.has?(type_name) }
						type_scope && type_scope[type_name]
					end
					declared_value = type_def[expr.value] if type_def

					if declared_value.is_a? Ore::Func
						# Use the actual function from the Type, not an empty wrapper
						func                 = declared_value.dup
						func.enclosing_scope = scope
						return func
					else
						# It's a variable/property
						return scope.send(proxy_method)
					end
				elsif scope.is_a?(Ore::Instance) && scope.enclosing_scope&.is_a?(Ore::Type) && scope.enclosing_scope&.has?(expr.value)
					if expr.type || expr.type_struct
						# A bare annotated identifier (`x: Number`) must self-declare its own per-instance copy, exactly like the nil-init idiom (`x,`) already does (see #interp_nil_init's identical shadowing fix) -- reading straight through to the enclosing Type's own nil placeholder instead would mean the instance never gets its own key, so a later `./x = value` would wrongly raise Cannot_Assign_Undeclared_Identifier.
						self_declare_annotated_identifier expr
					else
						# todo: This seems like a hack. This currently prevents instances from shadowing it's type's declarations.
						# Method/property exists on the Type, not the instance
						value = scope.enclosing_scope.get expr.value
						if value.is_a? Ore::Func
							func                 = value.dup
							func.enclosing_scope = scope
							return func
						else
							return value
						end
					end
				elsif expr.type || expr.type_struct
					self_declare_annotated_identifier expr
				else
					raise Ore::Undeclared_Identifier.new(expr, self)
				end
			else
				# When scope is nil, errors must be raised
				if expr.scope_operator&.value == '../'
					raise Ore::Cannot_Use_Type_Scope_Operator_Outside_Type.new(expr, self)
				elsif expr.scope_operator&.value == './'
					raise Ore::Cannot_Use_Instance_Scope_Operator_Outside_Instance.new(expr, self)
				elsif expr.type || expr.type_struct
					self_declare_annotated_identifier expr
				else
					raise Ore::Undeclared_Identifier.new(expr, self)
				end
			end

			# todo: Currently there is no clear rule on multiple unpacks. :double_unpack
			if expr.unpack && value.is_a?(Ore::Instance)
				stack.last.sibling_scopes << value
			end

			value
		end

		def interp_string expr
			return expr.value unless expr.interpolated

			interpolation_char_count = expr.value.count INTERPOLATE_CHAR
			if interpolation_char_count == 1
				return expr.value # For now... I think this is still not the correct approach.
			elsif interpolation_char_count > 1
				# todo: Proprely learn regex. For now, here's a description of what the regex below does:
				#
				# String: "Hi, `name`!"
				# Matches: ["name"]
				# Result: Interpolates the `name` variable

				# String: "Hi, \`name\`!"
				# Matches: []
				# Result: No interpolation, backslashes protect the backticks

				# String: "Hi, `first` and \`second\`"
				# Matches: ["first"]
				# Result: Only interpolates `first`, not `second`
				#

				result    = expr.value
				sub_exprs = result.scan(/(?<!\\)`(.*?)(?<!\\)`/).flatten

				sub_exprs.each do |sub|
					expression = Ore.parse sub
					value      = interpret expression.first
					result     = result.gsub "`#{sub}`", "#{stringify_for_display(value)}"
				end
				result.gsub('\\', '') # Remove any escapes from the resulting string? Is this okay? I don't know...
			end
		end

		def interp_prefix expr
			# note: See constants.rb PREFIX for exhaustive list of language-defined prefixes
			case expr.operator.value
			when '-'
				-interpret(expr.expression)
			when '+'
				+interpret(expr.expression)
			when '~'
				~interpret(expr.expression)
			when '!', 'not'
				!interpret(expr.expression)
			when 'return'
				returned = expr.expression ? interpret(expr.expression) : nil
				Ore::Return.new returned
			else
				overload_func = stack.reverse_each.find { |s| s.has? expr.operator.value }&.get(expr.operator.value)
				if overload_func.is_a? Ore::Func
					call           = Ore::Call_Expr.new
					call.arguments = [expr.expression]
					interp_func_body overload_func, call
				else
					raise Ore::Unhandled_Prefix.new(expr, self)
				end
			end
		end

		# @param expr [Ore::Infix_Expr]
		def interp_infix_assignment expr
			assignment_scope = scope_for_identifier expr.left # Reminder; this returns a scope whether or not the identifier exists

			# A type annotation (`x: Number = value`) is itself a declaration, so it's allowed to introduce a brand-new identifier just like `:=`, even though plain `=` otherwise requires the identifier to already exist. An inline signature (`x: Type{Param;} = value`) is the same idea — expr.left is a Func_Signature_Expr instead of a plain annotated Identifier_Expr, but it's just as self-declaring. A bare struct annotation (`thing: <String, Number> = value`) is self-declaring the same way, even with no `expr.left.type`.
			has_type_annotation = (expr.left.is_a?(Ore::Identifier_Expr) && (expr.left.type || expr.left.type_struct)) ||
			                      expr.left.is_a?(Ore::Func_Signature_Expr)
			assignment_scope    ||= stack.last if has_type_annotation

			# If using a scope operator but the scope doesn't exist, raise an error
			if expr.left.is_a?(Ore::Identifier_Expr) && expr.left.scope_operator && assignment_scope.nil?
				case expr.left.scope_operator.value
				when './'
					raise Ore::Cannot_Use_Instance_Scope_Operator_Outside_Instance.new(expr, self)
				when '../'
					raise Ore::Cannot_Use_Type_Scope_Operator_Outside_Type.new(expr, self)
				else
					raise Ore::Invalid_Scope_Syntax.new(expr, self)
				end
			end

			# For plain identifiers (no scope operator) inside an Instance/Type body, new declarations should go to that Instance/Type, not to an enclosing scope that happens to have the same identifier. This fixes a bug that prevented HTML Layout's `title` from capturing Title's `title` declaration in ore/examples/basic_html_page.ore.
			if expr.left.is_a?(Ore::Identifier_Expr) && !expr.left.scope_operator
				current_scope = stack.last

				if (current_scope.is_a?(Ore::Instance) || current_scope.is_a?(Ore::Type)) &&
				   assignment_scope != current_scope && !current_scope.has?(expr.left.value)
					# The identifier exists in some enclosing scope but not in the current
					# Instance/Type. Treat this as a new declaration on the current scope.
					assignment_scope = current_scope
				end
			end

			#
			# Special handling for load directive assignment, subscript, and maybe more later.
			#

			if expr.left.is_a? Ore::Subscript_Expr
				if expr.left.expression.expressions.count > 1
					raise Ore::Too_Many_Subscript_Expressions.new(expr.left, self)
				end
				# note: I'm interpreting only the first expression of left.expression.expressions as the key because the brackets are a Circumfix_Expr which uses an array to store the values.
				receiver = interpret expr.left.receiver
				key      = interpret expr.left.expression.expressions.first
				value    = interpret expr.right

				if receiver.is_a? Ore::Dictionary
					receiver.proxy_set key, value
					return receiver.proxy_get key
				else
					receiver[key] = value
					return receiver[key] # note: Intentionally returning the value here because the code starting with the directive check runs to the end of the method. todo: Imrpove?
				end
			end

			# Handle dot assignment
			if expr.left.is_a?(Ore::Infix_Expr) && expr.left.operator.value == '.'
				return assign_dot_member expr, expr.left, interpret(expr.right)
			end

			if expr.right.is_a?(Ore::Directive_Expr) && expr.right.name.value == Ore::IMPORT_FILE_DIRECTIVE
				filepath  = interpret expr.right.expression
				new_scope = Ore::Scope.new expr.left.value
				load_file_into_scope filepath, new_scope
				right_value = new_scope
			else
				right_value = interpret expr.right
			end

			# A Class-styled identifier (`My_Type = Other {}`) assigning a Scope value is itself a
			# declaration, same reasoning as has_type_annotation above: `=` onto a fresh
			# Class-styled name is how types get named/aliased, so it's allowed to introduce the
			# identifier rather than requiring `:=` first.
			is_class_declaration = Ore.type_of_identifier(expr.left.value) == :Identifier && right_value.is_a?(Ore::Scope)
			assignment_scope     ||= stack.last if is_class_declaration

			# Before the actual assignment, the identifier is checked for specific behavior errors based on its expression type (class, constant, variable/function)
			case Ore.type_of_identifier expr.left.value
			when :IDENTIFIER
				# It can only be assigned once, so if the declaration exists, fail. An undeclared
				# constant falls through to the Cannot_Reassign_Undeclared_Identifier check below.
				if assignment_scope&.has? expr.left.value
					raise Ore::Cannot_Reassign_Constant.new(expr.left, self)
				end
			when :Identifier
				# It can only be assigned `value` of Ore::Scope, which includes Ore::Type
				if !right_value.is_a?(Ore::Scope)
					raise Ore::Cannot_Assign_Incompatible_Type.new(expr, self)
				end
			when :identifier
				if assignment_scope
					# If the left side of the expression was declared with a type annotation, the type of `right_value` is enforced here.
					# `expr.left.type` covers the first, self-declaring assignment (the annotation is right here on this expression); the recorded type_by_identifier value covers every reassignment after that, once the annotation itself is gone. An inline signature (Func_Signature_Expr) supplies its own type directly, since it has no name to look up.
					type      = if expr.left.is_a? Ore::Func_Signature_Expr
						build_func_signature expr.left
					else
						expr.left.type&.value || assignment_scope.type_by_identifier[expr.left.value]
					end
					type      = type.name if type.is_a?(Ore::Type)
					signature = resolve_func_signature type

					if signature
						unless signature.matches? right_value
							raise Ore::Type_Contract_Violation.new(expr, signature.to_s, describe_value_shape(right_value), self)
						end
					else
						name = type_name_to_string(right_value)
						if type && name != type
							raise Ore::Type_Contract_Violation.new(expr, type, name, self)
						end
					end
				end
			end

			unless assignment_scope && (assignment_scope.has?(expr.left.value) || has_type_annotation || is_class_declaration)
				# it may not be declared using =
				raise Ore::Cannot_Assign_Undeclared_Identifier.new(expr, self)
			end

			if expr.left.is_a?(Ore::Identifier_Expr) && expr.left.type
				assignment_scope.type_by_identifier[expr.left.value] = expr.left.type.value
			elsif expr.left.is_a? Ore::Func_Signature_Expr
				# Recorded so future reassignments (which are plain Identifier_Exprs with no annotation of their own) still resolve back to this signature to check against.
				assignment_scope.type_by_identifier[expr.left.value] = build_func_signature expr.left
			end

			assignment_scope.declare expr.left.value, right_value
			track_static_declaration assignment_scope, expr.left

			return right_value
		end

		# todo; Types may be composed of multiple types, what happens in that case?
		# @param expr [Ore::Infix_Expr]
		def interp_infix_declaration expr
			# `(a, b) := <tuple-or-struct-valued expr>` -- destructuring, handled entirely separately
			# from the single-identifier case below (no scope operators, no type-by-identifier
			# locking against a bare `.value`, none of it applies to a target list).
			if expr.left.is_a?(Ore::Circumfix_Expr) && expr.left.grouping == '()'
				return interp_destructuring_declaration expr
			end

			# `thing.member := value` -- an external dot target, categorically different from
			# `./member := value` (a scope *operator*, parsed onto the Identifier_Expr itself, handled
			# by the has_scope_operator branch below -- this is a real Infix_Expr with `.` as the
			# receiver-and-member access operator). Strict: `.` never creates a member regardless of
			# `=` vs `:=` -- #assign_dot_member raises Cannot_Assign_Undeclared_Identifier if `member`
			# isn't already declared on whatever `thing` resolves to. For an existing member, `:=`
			# still means something distinct from `=` here: it re-infers/overwrites the recorded type
			# rather than checking the new value against it.
			if expr.left.is_a?(Ore::Infix_Expr) && expr.left.operator&.value == '.'
				return assign_dot_member expr, expr.left, interpret(expr.right), declare: true
			end

			# Only scope-operator forms (`../x`, `./x`, `.x`) target a specific scope. A plain `:=`
			# always declares on the current scope, shadowing any identically-named identifier in an
			# enclosing scope rather than re-declaring on it.
			has_scope_operator = expr.left.is_a?(Ore::Identifier_Expr) && expr.left.scope_operator
			assignment_scope   = scope_for_identifier expr.left if has_scope_operator

			# If using a scope operator but the scope doesn't exist, raise an error
			# (mirrors interp_infix_assignment).
			if has_scope_operator && assignment_scope.nil?
				case expr.left.scope_operator.value
				when './'
					raise Ore::Cannot_Use_Instance_Scope_Operator_Outside_Instance.new(expr, self)
				when '../'
					raise Ore::Cannot_Use_Type_Scope_Operator_Outside_Type.new(expr, self)
				else
					raise Ore::Invalid_Scope_Syntax.new(expr, self)
				end
			end

			assignment_scope ||= stack.last

			# note; `./`, `../` self-declaring a member that doesn't exist yet is valid but only while the instance is still under construction. Like within the class body's own declarations, or inside of new{;}
			if has_scope_operator && assignment_scope.is_a?(Ore::Instance) &&
			   !assignment_scope.has?(expr.left.value) && !assignment_scope.has?('new')
				raise Ore::Cannot_Assign_Undeclared_Identifier.new(expr, self)
			end

			right_value = if expr.right.is_a?(Ore::Directive_Expr) && expr.right.name.value == Ore::IMPORT_FILE_DIRECTIVE
				filepath  = interpret expr.right.expression
				new_scope = Ore::Scope.new expr.left.value
				load_file_into_scope filepath, new_scope
				new_scope
			else
				interpret expr.right
			end

			assignment_scope.declare expr.left.value, right_value

			assignment_scope.type_by_identifier[expr.left.value] = type_name_to_string right_value
			track_static_declaration assignment_scope, expr.left
			right_value
		end

		# `(a, b) := (1, 2)` / `(a, b) := <a: Number, b: Number>(1, 2)` -- declares each target identifier in the current scope from the source's own values, positionally. Asking for fewer values than the source has is fine (the rest are just discarded); asking for more raises Destructuring_Arity_Mismatch. Each target is one of two kinds, each mirroring an existing single-value form exactly:
		#
		#   - A plain local (`a`, or `x: Number` with an annotation) -- declares fresh on the current
		#     scope, same as the single-identifier `:=` case. An explicit `: Type` is checked against
		#     that position's extracted value.
		#
		#   - An existing member (`thing.member`) -- reassigns rather than declares, same as plain
		#     `thing.member = value`: the member must already exist, must not be a constant, and (if it
		#     has a previously-recorded type) the extracted value must match it.
		#
		def interp_destructuring_declaration expr
			targets = expr.left.expressions

			unless targets.all? { |target| destructuring_target? target }
				raise Ore::Invalid_Destructuring_Target.new(expr, self)
			end

			right_value = interpret expr.right
			values      = destructurable_values right_value

			unless values
				raise Ore::Invalid_Destructuring_Source.new(expr, self)
			end

			if targets.length > values.length
				raise Ore::Destructuring_Arity_Mismatch.new(expr, targets.length, values.length, self)
			end

			targets.each_with_index do |target, i|
				value = values[i]

				if target.is_a? Ore::Identifier_Expr
					declare_destructuring_local expr, target, value
				else
					assign_dot_member expr, target, value
				end
			end

			right_value
		end

		def destructuring_target? target
			target.is_a?(Ore::Identifier_Expr) ||
				(target.is_a?(Ore::Infix_Expr) && target.operator&.value == '.' && target.right.is_a?(Ore::Identifier_Expr))
		end

		def declare_destructuring_local expr, target, value
			if target.type
				expected = target.type.value
				actual   = type_name_to_string value
				if actual != expected
					raise Ore::Type_Contract_Violation.new(expr, expected, actual, self)
				end
			end

			assignment_scope = stack.last
			assignment_scope.declare target.value, value, type_name_to_string(value)
			track_static_declaration assignment_scope, target
		end

		# Shared by every way of writing through `.` onto an already-interpreted receiver: plain
		# `thing.member = value` / `thing.member := value`, and destructuring dot-targets
		# (`(thing.member, ...) := ...`). Strict: `.` never creates a member, no matter which of these
		# forms is used -- only `./`/`../` self-declaration, from inside a type's own body (its own
		# `new{;}` or any other method), gets to do that (handled entirely separately, by the
		# existing scope-operator path in #interp_infix_declaration/#interp_infix_assignment). So the
		# member must already be declared on the receiver, and must not be a constant (an UPPERCASE
		# member name). `declare: true` (the `:=` forms) re-infers/overwrites the member's recorded
		# type instead of checking it, same as re-running `:=` on a plain identifier does; `declare:
		# false` (the `=` forms, including destructuring targets) checks the extracted/assigned value
		# against any previously recorded type, raising Type_Contract_Violation on mismatch.
		def assign_dot_member expr, target, value, declare: false
			receiver = interpret target.left
			property = target.right.value

			unless receiver.is_a?(Ore::Scope) && receiver.has?(property)
				raise Ore::Cannot_Assign_Undeclared_Identifier.new(expr, self)
			end

			if Ore.type_of_identifier(property) == :IDENTIFIER
				raise Ore::Cannot_Reassign_Constant.new(expr, self)
			end

			check_dot_access_permissions! receiver, property, expr

			actual = type_name_to_string value
			if declare
				receiver.type_by_identifier[property] = actual
			else
				expected = receiver.type_by_identifier[property]
				if expected && actual != expected
					raise Ore::Type_Contract_Violation.new(expr, expected, actual, self)
				end
			end

			receiver[property] = value
			value
		end

		# Ore::Tuple/Ore::Struct both carry a plain Ruby-level `.values` reader holding the raw backing array (distinct from their Ore-level `.values` dot-access, which wraps the same data in an Ore::Array for Ore code to read).
		def destructurable_values value
			case value
			when Ore::Tuple, Ore::Struct
				value.values
			end
		end

		# @param expr [Ore::Infix_Expr]
		def interp_dot_infix expr
			return interp_dot_new expr if expr.right.is 'new'

			receiver = maybe_instance interpret expr.left

			unless receiver.kind_of?(Ore::Scope) || receiver.kind_of?(Ore::Range)
				raise Ore::Invalid_Dot_Infix_Left_Operand.new(expr, self)
			end

			case receiver
			when Ore::Array, Ore::Tuple
				interp_dot_array_or_tuple receiver, expr
			when Ore::Range
				interp_dot_range receiver, expr
			when Ore::Dictionary
				interp_dot_dictionary receiver, expr
			else
				# A structured type reference on the right (`ns.Abc<Number>`) isn't an Identifier_Expr, so it bypasses #interp_dot_scope's right-operand validation.
				if expr.right.instance_of? Ore::Type_Expr
					return interp_member_access receiver, expr.right
				end

				interp_dot_scope receiver, expr
			end
		rescue Ore::Undeclared_Identifier, Ore::Cannot_Call_Instance_Member_On_Type
			raise unless expr.operator.value == '.?'
			nil
		end

		# `@puts` used to hand its value straight to Ruby's own `puts`, which calls Ruby's `#to_s` for any Scope (Array, Dictionary, custom types, all of them).
		def stringify_for_display value
			value = maybe_instance value
			return value unless value.is_a? Ore::Scope

			to_s_ident        = Ore::Identifier_Expr.new
			to_s_ident.lexeme = Ore::Lexeme.new(:identifier, 'to_s')
			func              = begin
				interp_member_access value, to_s_ident
			rescue Ore::Undeclared_Identifier
				nil
			end
			return value unless func.is_a? Ore::Func

			call           = Ore::Call_Expr.new
			call.arguments = []
			interp_func_body func, call
		end

		# Interprets `expr` (the right side of `x.y`) scoped only to `receiver` and global scope, so a missing member can't fall through to an unrelated identically-named one still active further down the caller's stack (this caused a real infinite recursion before the fix).
		def interp_member_access receiver, expr
			saved_stack = stack
			self.stack  = [saved_stack.first, receiver]
			begin
				interpret expr
			ensure
				self.stack = saved_stack
			end
		end

		# Bare `X.new` (no parens) is equivalent to `X()`: full construction including `new{;}`, so a constructor with required params raises Missing_Argument. `X.new(...)` with parens never lands here; #interp_call intercepts it and routes to #interp_type_call directly.
		def interp_dot_new expr
			receiver = interpret expr.left
			unless receiver.is_a? Ore::Type
				raise Ore::Cannot_Initialize_Non_Type_Identifier.new(expr.left, self)
			end

			call           = Ore::Call_Expr.new
			call.receiver  = expr.left
			call.arguments = []
			interp_type_call receiver, call
		end

		# The dot sub-handlers below all take the receiver #interp_dot_infix already interpreted rather than re-interpreting expr.left themselves — re-interpreting ran the receiver expression's side effects (calls, constructions) a second or third time.
		def interp_dot_array_or_tuple scope, expr
			case
			when expr.right.is(Ore::Func_Expr) && expr.right.name.value == 'each'
				interp_each_loop scope, expr.right
				scope

			when expr.right.is(Ore::Number_Expr)
				scope.values[expr.right.value]

			when expr.right.is(Ore::Array_Index_Expr)
				expr.right.indices_in_order.reduce(scope) do |current, index|
					raise Ore::Invalid_Dot_Infix_Left_Operand.new(expr, self) unless current.is_a?(Ore::Array)
					current.proxy_get index
				end

			else
				interp_dot_scope scope, expr
			end
		end

		def interp_dot_range range, expr
			return interp_each_loop range, expr.right if expr.right.is(Ore::Func_Expr) && expr.right.name.value == 'each'
			interp_dot_scope range, expr
		end

		def interp_dot_dictionary dict, expr
			if expr.right.is_a? Ore::Identifier_Expr
				key_sym = expr.right.value.to_sym
				if dict.hash.has_key?(key_sym)
					return dict.hash[key_sym]
				end
			end

			interp_member_access dict, expr.right
		end

		def interp_dot_scope scope, expr
			raise Ore::Invalid_Dot_Infix_Left_Operand.new(expr, self) if scope.nil?
			raise Ore::Invalid_Dot_Infix_Right_Operand.new(expr.right, self) unless expr.right.instance_of? Ore::Identifier_Expr

			check_dot_access_permissions! scope, expr.right.value, expr

			interp_member_access scope, expr.right
		end

		def interp_each_loop collection, func_expr
			collection.each do |it|
				each_scope                 = Ore::Scope.new 'each{;}'
				each_scope.enclosing_scope = stack.last
				push_scope each_scope
				each_scope.declare 'it', it
				func_expr.expressions.each { |e| interpret e }
				pop_scope
			end
		end

		# The values for expr.operator, expr.left, and expr.right should all exist by this point
		# @param expr [Ore::Nil_Init_Expr]
		def interp_nil_init expr
			# attr_accessor :operator, :left, :right
			current_scope = stack.last

			# Same shadowing fix as interp_infix_assignment: inside an Instance/Type body, a plain
			# identifier's nil-init must declare on the current Instance/Type even if an enclosing
			# scope (e.g. the Type, whose body already ran once at definition time) already has an
			# identically-named identifier. Otherwise re-running `thing,` per-instance in
			# interp_type_call finds the Type's stale copy and never declares it on the instance.
			if (current_scope.is_a?(Ore::Instance) || current_scope.is_a?(Ore::Type)) && !current_scope.has?(expr.left.value)
				current_scope.declare expr.left.value, interpret(expr.right)
				track_static_declaration current_scope, expr.left
				return current_scope.get expr.left.value
			end

			begin
				return interpret expr.left
			rescue # Ore::Undeclared_Identifier and ArgumentError # todo: Why `ArgumentError: empty string`. Once this is resolved, then the rescue here should explicitly catch Undeclared_Identifier, probably.
				scope = scope_for_identifier(expr.left) || stack.last
				scope.declare expr.left.value, interpret(expr.right)

				track_static_declaration scope, expr.left
			end
		end

		# A bare annotated identifier (`x: Number`, `thing: <String, Number>`) that's never been declared behaves like the nil-init idiom (`ident,`) rather than raising Undeclared_Identifier
		def self_declare_annotated_identifier expr
			scope = stack.last
			scope.declare expr.value, nil
			track_static_declaration scope, expr
			nil
		end

		# A type's own @operator overload takes precedence over a same-named global one. Checks the operand's own declarations first, then its enclosing Type (for shorthand-constructed instances that never got the type's declarations copied onto themselves, see #interp_type_call), and only falls back to a global operator (excluding Type/Instance scopes, see the comment at the call site in #interp_infix) if neither applies.

		def find_operator_overload operator, operand = nil
			if operand.is_a?(Ore::Instance) && operand.has?(operator)
				return operand.get operator
			end

			if operand.is_a?(Ore::Scope) && operand.enclosing_scope.is_a?(Ore::Type) && operand.enclosing_scope.has?(operator)
				return operand.enclosing_scope.get operator
			end

			stack.reverse_each.find do |scope|
				!scope.is_a?(Ore::Type) && scope.has?(operator)
			end&.get(operator)
		end

		# Second-level dispatcher for infix operators, mirroring #interpret's own shape: each branch hands off to one interp_*_infix handler. The first group dispatches before operand evaluation — the assignment family treats the left side as a target rather than a value, `@` (the unpack marker) isn't a value at all, and logical operators must stay lazy to short-circuit. Every remaining operator evaluates each operand exactly once, here, and passes the values down so no handler re-interprets an operand (side effects run once).
		# @param expr [Ore::Infix_Expr]
		def interp_infix expr
			operator = expr.operator.value

			return interp_infix_assignment expr if operator == '='
			return interp_infix_declaration expr if operator == ':='
			return interp_dot_infix expr if operator == '.' || operator == '.?'
			return interp_unpack_infix expr if expr.left.value == Ore::BUILTIN_OPERATOR
			return interp_logical_infix expr if LOGICAL_OPERATORS.include? operator

			left  = interpret expr.left
			right = interpret expr.right

			case
			when INFIX_ARITHMETIC_OPERATORS.include?(operator)
				interp_arithmetic_infix expr, left, right
			when COMPARISON_OPERATORS.include?(operator)
				interp_comparison_infix expr, left, right
			when COMPOUND_OPERATORS.include?(operator)
				interp_compound_infix expr, left, right
			when RANGE_OPERATORS.include?(operator)
				interp_range_infix expr, left, right
			else
				interp_custom_infix expr, left, right
			end
		end

		# Calls an @operator overload as a regular two-argument function. `values` carries the operands when the caller already evaluated them; nil lets #interp_func_body evaluate the raw expressions once itself (only the lazy logical path needs that).
		def call_operator_overload overload, expr, values
			call           = Ore::Call_Expr.new
			call.arguments = [expr.left, expr.right]
			interp_func_body overload, call, arg_values: values
		end

		# `@ += instance` / `@ -= instance` — sibling-scope unpack control.
		# todo: Choose a different name for this, and a different character to use. @ is now gonna be exclusively "builtin" operator.
		def interp_unpack_infix expr
			case expr.operator.value
			when '+='
				right = interpret expr.right
				raise Ore::Invalid_Unpack_Infix_Right_Operand.new(expr, self) unless right.is_a? Ore::Scope
				stack.last.sibling_scopes << right
			when '-='
				right = interpret expr.right
				raise Ore::Invalid_Unpack_Infix_Right_Operand.new(expr, self) if right && !(right.is_a? Ore::Scope)
				stack.last.sibling_scopes.delete right
				# todo: Warn or error when trying to -= a scope that isn't a sibling?
			else
				raise Invalid_Unpack_Infix_Operator.new(expr, self)
			end
		end

		# Interprets its own operands (the one infix handler that does) because `&&`/`||` must short-circuit. A scope-level @operator overload still wins first, called with the raw expressions so the operands evaluate once, eagerly, inside the call.
		def interp_logical_infix expr
			overload = find_operator_overload expr.operator.value
			return call_operator_overload(overload, expr, nil) if overload.is_a? Ore::Func

			case expr.operator.value
			when '&&', 'and'
				interpret(expr.left) && interpret(expr.right)
			when '||', 'or'
				interpret(expr.left) || interpret(expr.right)
			when '&'
				interpret(expr.left) & interpret(expr.right)
			when '|'
				interpret(expr.left) | interpret(expr.right)
			end
		end

		# If left (or left's type) declares this operator via @operator, call it like a regular function with (left, right) as arguments. Falls back to left.enclosing_scope (the Type) because shorthand-constructed instances (array/string/dict literals, e.g. `[1, 2, 3]`) never get the type's own declarations copied down onto themselves the way `Array(...)`-style construction does (see #interp_type_call) -- this mirrors the same fallback #interp_identifier already does for regular method calls like `arr.push(...)`. Falls back further to a same-named global operator if the operand itself doesn't declare one.
		def interp_arithmetic_infix expr, left, right
			overload = find_operator_overload expr.operator.value, maybe_instance(left)

			if overload.is_a? Ore::Func
				call_operator_overload overload, expr, [left, right]
			else
				maybe_instance(left).send expr.operator.value, maybe_instance(right)
			end
		end

		# note; I'm special casing these because they don't behave like the traditional == and != in Ruby.
		def interp_comparison_infix expr, left, right
			case expr.operator.value
			when '===', '=!=', '=>=', '=<=', '=/='
				left_structure  = left.is_a?(Ore::Type) ? left.structure_instance&.types : nil
				right_structure = right.is_a?(Ore::Type) ? right.structure_instance&.types : nil

				# note; `left`/`right` are whatever #interpret returned (a raw Ruby Integer/String/etc for literals, not necessarily an Ore::Type/Instance), so `.types` can't be called on them directly. Using #composed_types_for here which resolves the correct composed-type set.
				left_types  = composed_types_for left
				right_types = composed_types_for right

				case expr.operator.value
				when '==='
					left_types == right_types && left_structure == right_structure

				when '=!='
					left_types != right_types || left_structure != right_structure

				when '=>='
					left_is_superset          = right_types.all? do |type|
						left_types.include? type
					end
					left_members_are_superset = (right_structure || []).all? do |member|
						(left_structure || []).include? member
					end

					left_is_superset && left_members_are_superset
				when '=<='
					right_is_superset = left_types.all? do |type|
						right_types.include? type
					end

					right_members_are_superset = (left_structure || []).all? do |member|
						(right_structure || []).include? member
					end

					right_is_superset && right_members_are_superset
				when '=/='
					shared_types   = left_types.any? do |type|
						right_types.include? type
					end
					shared_members = (left_structure || []).any? do |member|
						(right_structure || []).include? member
					end

					!shared_types && !shared_members
				end

			when '=~', '!~'
				# These behave just like Ruby's =~/!~: =~ returns the match index (or nil), !~ returns the boolean negation of a match.
				subject     = maybe_instance(left).value
				pattern     = maybe_instance(right).value
				match_index = subject =~ Regexp.new(pattern)

				expr.operator.value == '!~' ? match_index.nil? : match_index

			else
				# note; ==, !=, <, >, <=, >=, <=> aren't given fixed set-comparison semantics above, so — same as arithmetic — check for a user-declared @operator overload (on left itself, or falling back to left.enclosing_scope for shorthand-constructed instances, or a same-named global operator) before falling back to Ruby's own #==/#<=>/etc.
				overload = find_operator_overload expr.operator.value, left

				# note; A type declaring `@operator ==` but no `@operator !=` of its own (the common case ore/struct.ore's Member/Struct are exactly this) used to fall straight through to Ruby's own #!= for `!=`, which is identity-based and ignores the custom == entirely, two structurally-equal Members compared unequal with `!=` even though `==` correctly said they were equal. `!=` now derives from a declared `==` overload (negated) when it has no overload of its own, matching how most languages auto-derive != from ==.
				if !overload.is_a?(Ore::Func) && expr.operator.value == '!='
					overload      = find_operator_overload '==', left
					negate_result = true
				end

				if overload.is_a? Ore::Func
					result = call_operator_overload overload, expr, [left, right]
					negate_result ? !truthy?(result) : result
				else
					left.send expr.operator.value, right
				end
			end
		end

		# (a += b)  ==>  (a = (a + b)). Compound operators only ever consult a scope-level @operator overload (never the operand's own), since their built-in meaning is assignment, not a property of the operand's type.
		def interp_compound_infix expr, left, right
			overload = find_operator_overload expr.operator.value
			return call_operator_overload(overload, expr, [left, right]) if overload.is_a? Ore::Func

			base_op = expr.operator.value[..-2] # Trim the = from +=, -=, etc.
			result  = maybe_instance(left).send base_op, maybe_instance(right)

			# Assign back to left side
			assignment_scope = scope_for_identifier expr.left
			assignment_scope.declare expr.left.value, result
		end

		def interp_range_infix expr, start, finish
			overload = find_operator_overload expr.operator.value
			return call_operator_overload(overload, expr, [start, finish]) if overload.is_a? Ore::Func

			case expr.operator.value
			when '...'
				Ore::Range.new start, finish
			when '..<'
				Ore::Range.new start, finish, exclude_end: true
			when '>..'
				Ore::Range.new start + 1, finish
			when '>.<'
				Ore::Range.new start + 1, finish, exclude_end: true
			end
		end

		# A user-declared @operator with no built-in category of its own. The operand's own overload wins over a global one (#find_operator_overload). Reachable with no overload in scope when the operator is declared inside some other scope (the parser's pre-scan registers it file-wide) — that used to silently evaluate to nil; now it raises.
		def interp_custom_infix expr, left, right
			overload = find_operator_overload expr.operator.value, maybe_instance(left)
			unless overload.is_a? Ore::Func
				raise Ore::Undeclared_Infix_Operator.new(expr, self)
			end

			call_operator_overload overload, expr, [left, right]
		end

		# @param expr [Ore::Postfix_Expr]
		def interp_postfix expr
			# note: See constants.rb POSTFIX for exhaustive list of language-defined postfixes. Currently there are no built-in postfix operators.
			# 1) look up the opreator (expr.operator.value) as it should be a normal func in the scope.
			# 2) call it with expr.expression as its argument. It should only take one argument.
			postfix_overloaded_func = stack.reverse_each.find do |s|
				s.has? expr.operator.value
			end&.get(expr.operator.value)

			if !postfix_overloaded_func
				raise "Could not find #{expr.operator.value} declared anywhere man!"
			end

			call           = Ore::Call_Expr.new
			call.arguments = [expr.expression]
			interp_func_body postfix_overloaded_func, call
		end

		def interp_circumfix expr
			case expr.grouping
			when '[]'
				array             = Ore::Array.new
				array.expressions = expr.expressions

				values = []
				expr.expressions.each do |e|
					result = interpret e
					values << result
				end
				link_instance_to_type array, 'Array'

				# Make values accessible as an Ore identifier (`for values`, `arr.values`), sharing the same list object as the real backing store so mutations (push/pop/etc) stay in sync.
				array.values                 = values
				array.declarations['values'] = values

				array
			when '()'
				if expr.expressions.empty?
					tuple = Ore::Tuple.new []
					link_instance_to_type tuple, 'Tuple'
					tuple.declarations['values'] = tuple.values
					tuple
				elsif expr.expressions.count == 1
					# note: Single expressions should be treated as though they were not inside parentheses so that algebraic expressions can be grouped using parentheses. If I wrap single expressions in a Tuple then I have to also unwrap them later for arithmetic operations.
					interpret expr.expressions.first
				else
					values = expr.expressions.reduce([]) do |arr, expr|
						arr << interpret(expr)
					end
					tuple  = Ore::Tuple.new values
					link_instance_to_type tuple, 'Tuple'
					tuple.declarations['values'] = tuple.values
					tuple
				end
			when '{}'
				dict = expr.expressions.reduce(Ore::Dictionary.new) do |dict, it|
					if it.is_a? Ore::Identifier_Expr
						dict.proxy_set it.value.to_sym, nil
					elsif it.is_a? Ore::Infix_Expr
						case it.operator.value
						when ':', '='
							if it.left.is_a?(Ore::Identifier_Expr) || it.left.is_a?(Ore::Symbol_Expr) || it.left.is_a?(Ore::String_Expr)
								dict.proxy_set it.left.value.to_sym, interpret(it.right)
							else
								# The left operand should be allowed to be any hashable object. It's too early in the project to consider hashing but this'll be a good reminder.
								raise Ore::Invalid_Dictionary_Key.new(it, self)
							end
						else
							raise Ore::Invalid_Dictionary_Infix_Operator.new(it, self)
						end
					end
					# In case I forget, #reduce requires that the injected value be returned to be passed to the next iteration.
					dict
				end
				link_instance_to_type dict, 'Dictionary'
				dict
			else
				raise Ore::Unknown_Circumfix_Grouping.new(expr, self)
			end
		end

		# @param expr [Ore::Call_Expr]
		def interp_call expr
			# `X.new(...)` parses as Call_Expr(receiver: Infix_Expr(X, '.', new), arguments: [...]).
			# Intercept it here, before evaluating the receiver, so we don't route through
			# interp_dot_new (which eagerly builds a whole Instance for bare `X.new`) and then
			# build a second Instance via interp_type_call below. Bare `X.new` with no call
			# still goes through interp_dot_new untouched, since it never reaches interp_call.
			if expr.receiver.is_a?(Ore::Infix_Expr) && expr.receiver.operator&.value == '.' && expr.receiver.right.is('new')
				type = interpret expr.receiver.left

				unless type.is_a? Ore::Type
					raise Ore::Cannot_Initialize_Non_Type_Identifier.new(expr.receiver.left, self)
				end

				return interp_type_call type, expr
			end

			receiver = interpret expr.receiver

			# A nil-safe dot chain (`x.?method`) that found nothing evaluates to nil deliberately -- a trailing call (`x.?method()`) should short-circuit to nil too, not try to invoke nil.
			if receiver.nil? && expr.receiver.is_a?(Ore::Infix_Expr) && expr.receiver.operator&.value == '.?'
				return nil
			end

			case receiver
			when Ore::Route
				interp_func_body receiver.handler, expr

			when Ore::Func
				interp_func_body receiver, expr

			when Ore::Struct
				interp_struct_call receiver, expr

			when Ore::Instance, Ore::Type
				interp_type_call receiver, expr

			when Ore::Func_Signature
				raise Ore::Cannot_Call_Func_Signature.new expr, self

			else
				raise Ore::Cannot_Initialize_Non_Type_Identifier.new expr.receiver, self
			end
		end

		# @param expr [Ore::Type_Expr]
		def interp_type expr
			return interp_anonymous_composition expr if expr.anonymous_composition

			# No body was parsed (`x: Abc<Number>`, `y := Abc<Number>`, `Abc<Number>()`, `Abc<4815>()`) so this references an existing type rather than declaring one. Dup it so structuring this reference doesn't mutate the shared declaration every other reference sees.
			if expr.expressions.nil?
				if expr.struct
					supplied = interp_struct expr.struct, allow_spread: false

					# note; `expr.name` is normally a real type name ("String"), but if it's instead a local alias bound to an earlier structured reference (`X := String<Flying>`), re-structure against *that value's own* family name rather than treating "X" itself as a type name. So `X<duck>` should behave exactly like `String<duck>`, since `.name` on any Type object (dup'd or not) always reflects its true declared family.
					aliased     = find_in_stack expr.name
					lookup_name = aliased.is_a?(Ore::Type) ? aliased.name : expr.name

					existing = find_structured_type_variant lookup_name, supplied
					unless existing.is_a? Ore::Type
						raise Ore::Undeclared_Type_Structure.new(expr, self)
					end
				else
					existing = find_in_stack expr.name
					unless existing.is_a? Ore::Type
						raise Ore::Undeclared_Identifier.new(expr, self)
					end
				end

				# Object#dup is shallow so  @declarations/@static_declarations would still be the exact same Hash/Set every reference and the matched variant share, so structuring one would silently mutate all the others (and the variant itself). Fork them explicitly.
				referenced                     = existing.dup
				referenced.declarations        = existing.declarations.dup
				referenced.static_declarations = (existing.static_declarations || Set.new).dup
				if expr.struct
					# Call-site member values are always positional (`Woof<'hello', 4815>`, never `Woof<key: 'hello'>`) for now! Here we re-associate them with the names — and pick up any defaults — from the matched variant's own struct declaration (`Woof<String, key: Dictionary> {}`) so `.structure.key` still works on the resulting instance.
					# Eventually I want to support named arguments like <key='hello'>.
					declaration            = existing.structure_declaration
					declaration_names      = declaration.is_a?(Ore::Struct) ? declaration.names : []
					declaration_types      = declaration.is_a?(Ore::Struct) ? declaration.type_objects : [] # declared type objects, used below only to detect an unfilled default via identity
					declaration_type_names = declaration.is_a?(Ore::Struct) ? declaration.type_names : []
					declaration_values     = declaration.is_a?(Ore::Struct) ? declaration.values : []

					# A default only fills in for a member that just re-asserts the declaration's own declared type for that member (`Abc<Dictionary>()`, re-stating `dict`'s own type rather than giving it a value) — never when a real value was actually supplied there (`Abc<{x=1}>()` must keep {x=1}, not fall back to the default).
					resolved_values = supplied.type_objects.each_with_index.map do |value, i|
						name = declaration_names[i]
						if name && !declaration_values[i].nil? && value.equal?(declaration_types[i])
							declaration_values[i]
						else
							value
						end
					end

					referenced.structure_instance = build_struct declaration_names, declaration_type_names, resolved_values, resolved_values
				end
				declare_structure referenced
				return referenced
			end

			if expr.struct
				interp_structured_type_declaration expr
			else
				interp_bare_type_declaration expr
			end
		end

		# A composition chain with no `{}` body (`Abc|Def`, `A & B`, ...) is a value, not a declaration, built by applying the chain to a fresh, unnamed Type exactly as if `X | Abc | Def { }` had been written for some unnamed X.
		def interp_anonymous_composition expr
			anonymous             = Ore::Type.new nil
			anonymous.types       = Set.new # Type#initialize seeds `@types = Set[name]` -- Set[nil] here, which would leave a stray nil in .types (breaking #find_ruby_class_for_type's `"Ore::#{type_name}"` lookup) since the union step below only ever adds, never resets.
			anonymous.expressions = [] # A real declaration always ends up with this set (even to []) via #interp_bare_type_declaration's own body-merge -- there's no body here, but #run_type_body_on_instance still expects an Array to iterate when constructing an instance.

			seed            = Ore::Composition_Expr.new
			seed.operator   = Ore::Lexeme.new(:operator, '|')
			seed.identifier = Ore::Identifier_Expr.new.tap { |it| it.lexeme = Ore::Lexeme.new(:Identifier, expr.name) }

			push_then_pop anonymous do
				interp_composition seed
				expr.expressions.each { |composition| interp_composition composition }
			end

			anonymous
		end

		# Shared tail of both declaration paths below: parent the type to the declaring scope, link it to its Ore:: Ruby class when one exists, record its own name in @types, and run `body_expressions` in the type's scope.
		def finish_type_declaration type, body_expressions
			type.enclosing_scope = stack.last

			ore_name = "Ore::#{type.name}"
			defined  = type.name[0] != '_' && Object.const_defined?(ore_name) # note; #const_defined? does not allow underscore as the first character, hence the underscore check.
			link_instance_to_type type, type.name if defined

			type.types ||= []
			type.types << type.name
			type.types = type.types.uniq

			push_then_pop type do
				body_expressions.each do |sub_expr|
					interpret sub_expr
				end
			end

			type
		end

		# A plain, unstructured declaration (`String { ... }`) -- reopens/extends the same shared Type object across multiple declarations of the same bare name, e.g. how preload.ore's files each contribute to the same base String/Array/etc.
		def interp_bare_type_declaration expr
			existing = stack.last.has?(expr.name) && stack.last[expr.name]
			type     = existing.is_a?(Ore::Type) ? existing : Ore::Type.new(expr.name)

			type.expressions = (type.expressions || []) + expr.expressions
			finish_type_declaration type, expr.expressions

			stack.last.declare type.name, type
			type
		end

		# A structured declaration (`String<dict: Dictionary> { ... }`) is its own type, separate from the bare `String` and every other struct under the same name -- this stops one variant's `new`/methods from clobbering another's (a real bug this fixed).
		def interp_structured_type_declaration expr
			struct = interpret expr.struct

			existing = structured_variants_for(expr.name, current_scope_only: true).find do |variant|
				variant.structure_declaration.structure_declaration_equal? struct
			end

			if existing
				variant = existing
			else
				variant             = Ore::Type.new(expr.name)
				blueprint           = stack.last.has?(expr.name) && stack.last[expr.name]
				variant.expressions = blueprint.is_a?(Ore::Type) ? (blueprint.expressions || []).dup : []
			end

			variant.expressions           = (variant.expressions || []) + expr.expressions
			variant.structure_declaration = struct

			# A reopened variant already ran its earlier body when it was declared, so only the new expressions run now (matching the bare path). A fresh variant runs everything, including the bare blueprint's copied body.
			finish_type_declaration variant, (existing ? expr.expressions : variant.expressions)

			stack.last.structured_type_variants[expr.name] << variant unless existing
			variant
		end

		# All type names a supplied member value could match a declared struct's member under -- its own primary name first, then everything it composes, so e.g. a `Div` satisfies a member declared `Dom` without being named Dom itself. See #find_structured_type_variant.
		def member_candidate_type_names value
			case value
			when ::Integer, ::Float
				['Number']
			when ::String
				['String']
			when ::Symbol
				['Symbol']
			when ::TrueClass, ::FalseClass
				['Bool']
			else
				if value.is_a?(Ore::Type) && value.types && !value.types.empty?
					value.types.to_a
				else
					[value.name]
				end
			end
		end

		# Finds the declared variant a reference's supplied structure matches. A reference member can optionally be named (`String<other := {x=1}>()`, reusing the same bare-`:=` idiom declarations use) to disambiguate when more than one declared variant would otherwise match by type alone. Narrows to variants agreeing on every explicitly-named member first, then prefers an exact type match before falling back to anything a value merely composes.
		def find_structured_type_variant base_name, supplied
			values = supplied.type_objects
			return nil if values.nil? || values.empty?

			variants = structured_variants_for base_name
			return nil if variants.empty?

			candidate_lists = values.map { |value| member_candidate_type_names value }
			return nil if candidate_lists.any?(&:empty?)

			names      = supplied.names || []
			candidates = variants.select do |variant|
				declared_names = variant.structure_declaration.names
				names.each_with_index.all? { |name, i| name.nil? || declared_names[i] == name }
			end

			exact_types = candidate_lists.map(&:first)
			candidates.find { |variant| variant.structure_declaration.type_names == exact_types } ||
				candidates.find { |variant| variant.structure_declaration.satisfied_by_candidates? candidate_lists }
		end

		# Structured variants declared under `base_name`, searched the same way #find_in_stack resolves a
		# plain identifier -- innermost to outermost, stopping at the first scope that has any (lexical
		# shadowing, not merging). `current_scope_only` restricts the search to `stack.last` alone, for
		# declaration-time collision checks -- a nested structured declaration should only ever collide with
		# another declared in that exact scope, never one from an enclosing one.
		def structured_variants_for base_name, current_scope_only: false
			scopes = current_scope_only ? [stack.last] : stack.reverse_each
			scopes.each do |scope|
				list = scope.structured_type_variants.fetch(base_name, [])
				return list unless list.empty?
			end
			[]
		end

		# Searches the full scope stack (innermost to outermost) for `key`, the same way a bare identifier resolves via #scope_for_identifier -- checking only `stack.last` would miss a type declared in an outer/global scope while evaluating from inside a nested context (e.g. a type's own declaration body during composition).
		def find_in_stack key
			stack.reverse_each do |scope|
				return scope[key] if scope.has? key
			end
			nil
		end

		# Makes `.structure` readable via Ore dot-access on a Type, Instance, or type reference, and marks it static so it's also readable straight off a bare Type (not just an instance). Only adds the declaration when this particular one actually has a structure, so plain unstructured types don't pick up a stray `structure` member.
		def declare_structure scope
			return unless scope.structure_instance

			scope.declarations['structure'] = scope.structure_instance
			scope.static_declarations       = (scope.static_declarations || Set.new) + ['structure']
		end

		#
		# Ore::Type_Expr is converted to Ore::Type in #interp_type.
		# Ore::Instance inherits Ore::Type's @name and @types.
		#
		#     (See types.rb for Ore::Type and Ore::Instance declarations)
		#     (See expressions.rb for Ore::Type_Expr declaration)
		#
		# - Push instance onto stack
		# - Interpret type.expressions so the declarations are made on the instance
		# - Keep instance on the stack
		# - For each Ore::Func declared on instance, set `func.enclosing_scope = instance`
		# - Interpret instance[:new], the initializer
		# - Delete :new from instance, no longer needed
		#
		# note: There was a bug here where I wasn't popping the instance after interpreting the type's expressions. That caused the #new function below (func_new) to not properly interpret arguments passed to it.
		# note: We push type.enclosing_scope first (when present) so sibling types declared in the same scope can be found during instantiation.
		def run_type_body_on_instance type, instance
			interpret_instance_body = -> do
				push_then_pop type do
					push_then_pop instance do |scope|
						type.expressions.each do |expr|
							# Skip static declarations - they were already executed during type definition and shouldn't be re-executed for each instance
							if expr.is_a?(Ore::Infix_Expr) && expr.operator&.value == ':=' &&
							   expr.left.is_a?(Ore::Identifier_Expr) && expr.left.scope_operator&.value == '../'
								next
							end

							if expr.is_a?(Ore::Func_Expr) && expr.name.is_a?(Ore::Identifier_Expr) &&
							   expr.name.scope_operator&.value == '../'
								next
							end

							interpret expr
						end
					end
				end
			end

			if type.enclosing_scope
				push_then_pop type.enclosing_scope do
					interpret_instance_body.call
				end
			else
				interpret_instance_body.call
			end

			instance.declarations.each do |key, decl|
				next unless decl.is_a? Ore::Func

				cloned                     = decl.dup
				cloned.enclosing_scope     = instance
				instance.declarations[key] = cloned
			end
		end

		# Builds the raw instance for #interp_type_call: backed by its Ore:: Ruby class when one exists, linked to its type, struct bound, and the type's body run on it. `new{;}` is invoked afterward by #interp_type_call itself.
		def build_instance_of_type type
			ruby_class = find_ruby_class_for_type type
			instance   = ruby_class ? ruby_class.new : Ore::Instance.new(type.name)

			instance.name            = type.name
			instance.types           = type.types
			instance.enclosing_scope = type
			instance.expressions     = type.expressions

			# note; Bind structs onto the instance before the type's expressions (and therefore `new`) are interpreted below, so `new{;}`'s own body can reference `.structure`. This is a completely separate binding path from the call's own arguments — member values never get forwarded into `new`'s params.
			effective_structure = type.structure_instance || type.structure_declaration
			if effective_structure
				instance.structure_instance = effective_structure
				declare_structure instance
			end

			run_type_body_on_instance type, instance
			instance
		end

		def interp_type_call type, expr
			instance = build_instance_of_type type

			func_new = instance[:new]
			if func_new
				interp_func_body func_new, expr
			else
				if expr.arguments.count > 0
					raise Ore::Arguments_Given_But_Not_Expected.new(expr, self)
				end
			end

			instance.delete :new
			instance
		end

		def interp_func_signature expr
			signature = build_func_signature expr

			if expr.name&.value
				stack.last.declare expr.name.value, signature
				# Recorded so a later plain reassignment (`double = ...`, a bare Identifier_Expr with
				# no annotation of its own) still resolves back to this signature to check against --
				# mirrors what #interp_infix_assignment records for the `name: {...} = value` form.
				# Without this, a bare declaration (`double: {Number -> Number;}`, no `=`) left nothing
				# for #resolve_func_signature to find, so `double = {String -> String;}` right after
				# went unchecked.
				stack.last.type_by_identifier[expr.name.value] = signature
			end

			signature
		end

		def interp_func expr
			func                 = Ore::Func.new expr.lexeme
			func.name            = expr.lexeme
			func.enclosing_scope = stack.last
			func.expressions     = expr.expressions

			param_types         = expr.expressions.select do |e|
				e.is_a? Ore::Param_Expr
			end.map do |p|
				p.type&.value
			end
			func.func_signature = Ore::Func_Signature.new(param_types, expr.type&.value)

			if func.name&.value
				stack.last.declare func.name.value, func

				track_static_declaration stack.last, expr.name
			end

			func
		end

		def interp_func_body func, expr, arg_values: nil
			params = func.expressions.select do |expr|
				expr.is_a? Ore::Param_Expr
			end

			# note; Evaluate arguments in caller's scope (before pushing function scopes). A labeled argument (`to: someone`) parses as a plain `:` Infix_Expr (same production named struct members use) so unwrap it here rather than letting #interpret try to resolve `to` as an identifier and raise Undeclared_Identifier.
			# A caller that already evaluated the operands (operator-overload dispatch in #interp_infix) passes them via arg_values so their side effects don't run a second time; labels only exist in real call syntax, so none apply there.
			arg_labels = []
			arg_values ||= expr.arguments.map do |arg|
				label, value_expr = argument_label_and_expr arg
				arg_labels << label
				interpret value_expr
			end

			# note: `func` is the single, shared Func object registered when the function was declared. Pushing it directly as the call frame (as this used to do) meant every invocation declared its params onto that same shared object, so recursive/repeated calls stomped on each other's param values. Each call gets its own fresh scope instead.
			call_scope                 = Ore::Func.new func.name
			call_scope.expressions     = func.expressions
			call_scope.enclosing_scope = func.enclosing_scope
			call_scope.arguments       = arg_values

			# Push type scope if calling an instance method (instance methods need access to type-level declarations)
			# Also push the type's enclosing_scope so sibling types can be found
			if func.enclosing_scope.is_a?(Ore::Instance) && func.enclosing_scope.enclosing_scope
				type = func.enclosing_scope.enclosing_scope
				push_scope type.enclosing_scope if type.enclosing_scope # Push the Type's enclosing scope
				push_scope type # Push the Type
			end
			push_scope func.enclosing_scope
			push_scope call_scope

			params.each_with_index do |param, i|
				value = if i < arg_values.length
					arg_values[i]
				elsif param.default
					interpret param.default
				else
					raise Ore::Missing_Argument.new(expr, self)
				end

				# Labels are positional, not a lookup key -- a labeled argument at position `i` must
				# match that position's declared label (Swift/ObjC-style), never used to reorder
				# arguments. A bare, unlabeled argument is always accepted regardless of whether the
				# param declares a label -- labels are opt-in at the call site, not mandatory.
				supplied_label = arg_labels[i]
				if supplied_label && supplied_label != param.label&.value
					raise Ore::Argument_Label_Mismatch.new(expr, param.label&.value, supplied_label, self)
				end

				stack.last.declare param.name.value, value

				if param.unpack && value.is_a?(Ore::Instance)
					call_scope.sibling_scopes << value
				end
			end

			body = call_scope.expressions - params
			if call_scope.name == 'assert'
				raise Ore::Assert_Triggered.new(expr, self) unless interpret(body.first) == true # Just to be explicit.
			end

			result = nil
			body.compact.each do |e|
				next if e.is_a? Ore::Param_Expr # Or just remove Param expressions from

				result = interpret e
				break if result.is_a? Ore::Return
			end

			Ore.assert pop_scope == call_scope
			Ore.assert pop_scope == func.enclosing_scope

			if func.enclosing_scope.is_a?(Ore::Instance) && func.enclosing_scope.enclosing_scope
				type = func.enclosing_scope.enclosing_scope
				Ore.assert pop_scope == type
				pop_scope if type.enclosing_scope # Pop the Type's enclosing scope
			end

			return_value = result.is_a?(Ore::Return) ? result.value : result

			if func.func_signature.return_type
				actual_type = type_name_to_string return_value
				if actual_type != func.func_signature.return_type
					raise Ore::Type_Contract_Violation.new(expr, func.func_signature.return_type, actual_type, self)
				end
			end

			return_value
		end

		# A call argument written as `label: value` parses as a plain `:` Infix_Expr (same production named struct members use). returns [label, value_expr] for that shape, or [nil, arg] for a plain positional argument. Never interprets `arg`/the label side itself; that's the caller's job once it knows which expression actually holds the real value.
		def argument_label_and_expr arg
			if arg.is_a?(Ore::Infix_Expr) && arg.operator&.value == ':' && arg.left.is_a?(Ore::Identifier_Expr)
				[arg.left.value, arg.right]
			else
				[nil, arg]
			end
		end

		# `<name: String, age: Number>` alone is a structure-only (each named member's declared type, no real data yet; see #interp_struct). `()` is how you turn that struct into an actual instance: the call's own arguments become each member's real value, positionally, same order as declared. Goes through #build_struct like every other struct construction so a declared `Struct` type's own body/methods still run.
		#
		# @param struct [Ore::Struct]
		# @param expr [Ore::Call_Expr]
		def interp_struct_call struct, expr
			values = expr.arguments.map { |arg| wrap_struct_string_value(arg, interpret(arg)) }
			build_struct struct.names, struct.type_names, struct.type_objects, values
		end

		# @param expr [Ore::Route_Expr]
		# @return Ore::Route
		def interp_route expr
			func = interpret expr.expression

			route                 = Ore::Route.new
			route.name            = func.name
			route.enclosing_scope = stack.last
			route.handler         = func
			route.http_method     = expr.http_method
			route.path            = expr.path
			route.path            = route.path[1..] if route.path.start_with? '/'
			route.param_names     = expr.param_names || []

			route.parts = route.path.split('/').reject do
				_1.empty?
			end

			# Always keyed by "method:path", even when the handler is a named function
			# (`get://path some_handler`) — the name identifies the *function*, not the route, and two
			# different routes can legitimately share one handler. Keying by name instead used to
			# collide in exactly that case, silently dropping every route but the last to reuse a name.
			route_key = "#{route.http_method.value}:#{route.path}"

			# Store route in the enclosing Type's @routes if it has one (e.g., Server)
			enclosing_type = stack.reverse.find do |scope|
				scope.is_a? Ore::Type # note: You could have an instance on the stack, or an empty scope, whatever.
			end
			if enclosing_type
				enclosing_type.routes            ||= {}
				enclosing_type.routes[route_key] = route
			end

			@route_functions_by_route_name[route_key] = route
			stack.last.declare route_key, route

			route
		end

		# @param route [Ore::Route] The route to execute
		# @param req [Ore::Request] Request object to inject
		# @param res [Ore::Response] Response object to inject
		# @param url_params [Hash] Extracted URL parameters (e.g., {"id" => "123"})
		# @param server_instance [Ore::Instance] The server instance (for accessing instance variables)
		# @return The result of handler execution
		def interp_route_body route, req, res, url_params = {}, server_instance: nil
			handler = route.handler
			params  = handler.expressions.select { |e| e.is_a? Ore::Param_Expr }

			call_scope = Ore::Scope.new "#{handler.name || 'anonymous'}_route"
			push_scope handler.enclosing_scope
			push_scope server_instance if server_instance
			push_scope call_scope

			# Make request and response available without explicit declaration
			call_scope.declare 'request', req
			call_scope.declare 'response', res

			# Bind URL parameters as function arguments. For example, get://:abc/:def { abc, def; }
			params.each do |param|
				value = url_params[param.name.value] || url_params[param.name.value.to_sym]

				if value.nil?
					if route.param_names.include? param.name.value
						# todo: I haven't triggered this yet to ensure this works.
						raise Ore::Route_Param_Expected_But_Not_Found.new(route, self)
					end

					# Use default value or raise
					if param.default
						value = interpret param.default
					else
						# todo: Is this reachable?
						raise Ore::Missing_Argument.new(expr, self)
					end
				end

				call_scope.declare param.name.value, value
			end

			body   = handler.expressions - params
			result = nil

			body.compact.each do |expr|
				# bug todo: Sometimes body contains `nil` when that should never be the case
				next if expr.is_a? Ore::Param_Expr # Reminder, param expressions are part of the function body by design. This is redundant because I'm subtracting the params from the handler expressions a few lines above, but just in case!

				result = interpret expr
				break if result.is_a? Ore::Return
			end

			if result.is_a? ::String
				res.declarations['body'] = result
			elsif result.is_a? Ore::Array
				html = ''
				result.values.each do |it|
					if it.is_a? ::String
						html += it
					elsif it.is_a?(Ore::Instance) && it.types.include?('Dom')
						html += render_dom_to_html it
					end
				end
				res.declarations['body'] = html
			elsif result.is_a? Ore::Instance
				# todo: Maybe find a better class name than Dom, and add a constant for it.
				if result.types.include? 'Dom'
					html                     = render_dom_to_html result
					res.declarations['body'] = html
				else
					res.declarations['body'] = result.inspect
				end
			end

			# Clean up scopes in reverse order
			popped_call = pop_scope
			Ore.assert popped_call == call_scope

			if server_instance
				popped_instance = pop_scope
				Ore.assert popped_instance == server_instance
			end

			popped_enclosing = pop_scope
			Ore.assert popped_enclosing == handler.enclosing_scope

			result
		end

		# @param expr [Ore::Fence_Expr]
		def interp_fence expr
			Ore::Fence.new expr.value # note: Ore::Fence extends Ore::String
		end

		# @param expr [Ore::Html_Fence_Expr]
		def interp_html_fence expr
			interp_string expr.body
		end

		def interp_composition expr
			# These are interpreted sequentially, so there are no precedence rules. I think that'll be better in the long term because there's no magic behind their evaluation. You can ensure the correct outcome by using these operators to form the types you need.

			right      = maybe_instance interpret expr.identifier
			unless right.is_a? Ore::Scope
				raise Ore::Invalid_Composition_With_A_Non_Scope_type.new(right, self)
			end
			curr_scope = stack.last

			case expr.operator.value
			when '|'
				# Union with Ore::Type

				right.declarations.each do |key, value|
					curr_scope[key] = value unless curr_scope.has?(key)
				end

				curr_scope.static_declarations ||= Set.new
				curr_scope.static_declarations.merge right.static_declarations

				curr_scope.types ||= []
				curr_scope.types += right.types
				curr_scope.types = curr_scope.types.uniq
			when '~'
				# Removal of Ore::Type

				operand_keys_to_remove = right.declarations.keys

				# Maybe I'll have other keys to protect in the future.
				operand_keys_to_remove.reject! do |key|
					key.to_s == 'new'
				end

				operand_keys_to_remove.each do |key|
					curr_scope.delete key
				end

				curr_scope.static_declarations.subtract right.static_declarations

				curr_scope.types = curr_scope.types.reject do |type|
					type == expr.identifier.value
				end
			when '&'
				# Intersection of Types, aka what they share.

				shared_keys    = right.declarations.keys.select do |key|
					curr_scope.has? key
				end
				keys_to_delete = curr_scope.declarations.keys - shared_keys

				keys_to_delete.each do |key|
					curr_scope.declarations.delete key
				end

				curr_scope.static_declarations = curr_scope.static_declarations & right.static_declarations

			when '^'
				# Symmetric difference of Types, aka what they don't share.

				shared_keys = curr_scope.declarations.keys.select do |key|
					right.has? key
				end

				current_unique_keys = curr_scope.declarations.keys - shared_keys
				operand_unique_keys = right.declarations.keys - shared_keys
				keys_to_keep        = current_unique_keys + operand_unique_keys

				curr_scope.declarations.delete_if do |key, _|
					!keys_to_keep.include? key
				end

				curr_scope.static_declarations = curr_scope.static_declarations ^ right.static_declarations

				operand_unique_keys.each do |key|
					curr_scope[key] = right[key]
				end
			else
				raise Ore::Invalid_Composition_Operator.new(expr, self)
			end
		end

		# @param for_loop_expr [Ore::For_Loop_Expr]
		def interp_for_loop for_loop_expr
			collection = interpret for_loop_expr.collection
			stride     = interpret(for_loop_expr.stride) if for_loop_expr.stride

			Ore.assert stride.nil? || stride.is_a?(Integer), "Stride must be an integer" if stride

			loop_type = for_loop_expr.type&.value || 'each' # one of Ore::FOR_VERBS
			result    = nil

			push_then_pop Scope.new('for_loop') do |scope|
				values = case collection

				when Ore::Dictionary
					collection.hash
				when Ore::Array
					collection.values

				when Ore::Range
					collection
				when Ore::String
					collection.value.chars

				when Ore::Struct
					# `.members` (an `Ore::Array` of `Ore::Member`) is only populated when the opt-in `ore/struct.ore` layer is loaded (see #build_struct) -- a bare Struct with no matching declared `Struct` type has nothing to iterate.
					collection.declarations['members']&.values || []

				else
					collection # todo; This could be a number, and every other object in the language.
				end

				# New for-loop verbs, to be handled with stride and without
				#
				#   for <collection> [verb: map/select/reject] [by <stride>]
				#   end
				#
				iterate_body = -> (element, index) do
					scope.declare 'it', element
					scope.declare 'at', index
					body_result = nil
					catch :skip do
						for_loop_expr.body.each do |e|
							body_result = interpret e
							throw(:stop, body_result) if body_result.is_a? Ore::Return
						end
					end
					body_result
				end

				# Initialize collection variables outside catch block so they persist after stop
				collected = []
				count_val = 0
				elements  = if stride && !collection.is_a?(Ore::Dictionary)
					values.each_slice(stride).each_with_index
				else
					values.each_with_index
				end

				stop_value = catch :stop do
					elements.each do |element, index|
						if collection.is_a? Ore::Dictionary
							new_it = element[1]
							new_at = element[0]
							scope.declare 'it', new_it
							scope.declare 'value', new_it
							scope.declare 'at', new_at
							scope.declare 'key', new_at
							element = new_it
							index   = new_at
						end

						case loop_type
						when 'each'
							result = iterate_body.call element, index
						when 'map'
							collected << iterate_body.call(element, index)
						when 'select'
							collected << element if truthy? iterate_body.call(element, index)
						when 'reject'
							collected << element unless truthy? iterate_body.call(element, index)
						when 'count'
							count_val += 1 if truthy? iterate_body.call(element, index)
						end
					end
					nil
				end

				# Assign results after catch block so partial results are preserved on stop
				case loop_type
				when 'map', 'select', 'reject'
					result = Ore::Array.new(collected)
				when 'count'
					result = count_val
				end

				result     = stop_value if stop_value.is_a? Ore::Return
			end # of push_then_pop

			result
		end

		def interp_conditional expr
			# All conditional forms (if/unless/while/until) use #truthy? uniformly now -- `if`/`while` used to require the condition be the literal value `true`, so `if [1,2,3]` never took its true branch.
			case expr.type.value
			when 'while', 'until', 'elwhile'
				result    = nil
				condition = interpret expr.condition

				index           = 0
				on_skip_handler = Proc.new do
					index += 1
					stack.last.declare 'at', index

					expr.when_true.each do |stmt|
						result = interpret(stmt)
					end
				end

				iteration_proc = Proc.new do
					catch :skip do
						on_skip_handler.call
					end
					condition = interpret(expr.condition)
				end

				catch :stop do
					if expr.type.value == 'until'
						until truthy? condition
							iteration_proc.call
						end
					else
						while truthy? condition
							iteration_proc.call
						end
					end
				end

				if expr.when_false.is_a? Ore::Conditional_Expr
					result = interp_conditional expr.when_false
				elsif expr.when_false.is_a? ::Array
					expr.when_false.each do |expr|
						result = interpret expr
					end
				end

				return result
			when 'unless'
				# @Copypaste from the else clause below. This is simple to factor out.
				condition = interpret expr.condition
				body      = if truthy? condition
					expr.when_false
				else
					expr.when_true
				end

				if body.is_a? Ore::Conditional_Expr
					interp_conditional body
				else
					body.each.inject(nil) do |result, expr|
						interpret expr
					end
				end

			else
				condition = interpret expr.condition
				body      = if truthy? condition
					expr.when_true
				else
					expr.when_false
				end

				if body.is_a? Ore::Conditional_Expr
					interp_conditional body
				else
					result = body.each.inject(nil) do |result, expr|
						interpret expr
					end

					result || nil
				end
			end
		end

		def interp_directive expr
			case expr.name.value
			when 'declare'
				# todo; `@declare "ident", value, Type`
				if expr.expression.is_a? Ore::Struct
					# then declare all the members
					expr.expression.members.each do |member|
						next unless member.name
						# @param member [Ore::Member]
						# :name, :type, :value
						stack.last.declare member.name, member.value, member.type
					end
					return interpret expr.expression
				end

				data = (expr.arguments || []).map { |arg| interpret arg }

				case data.count
				when 1
					# name
					stack.last.declare data[0], nil
				when 2
					# name, value
					stack.last.declare data[0], data[1]
				when 3
					# name, value, type
					stack.last.declare data[0], data[1], data[2]
				else
					raise Ore::Invalid_Directive_Usage.new(expr, self)
				end
			when 'puts'
				value = expr.expression ? interpret(expr.expression) : nil
				puts stringify_for_display(value) # note: Don't remove this like I did, it is supposed to print out. todo: Be able to set your own output stream
				value
			when 'assert'
				condition = interpret expr.expression
				unless condition
					message = interpret expr.message if expr.message
					raise Ore::Assert_Triggered.new(expr, self, message)
				end
			when 'ruby'
				# The @ruby directive evaluates to the result of calling the ruby Ruby method
				func_scope = stack.last
				unless func_scope.is_a? Ore::Func
					raise Ore::Invalid_Ruby_Proxy_Directive_Usage.new func_scope, self
				end

				func_name        = func_scope.name
				proxy_method     = "proxy_#{func_name.value}"
				instance_or_type = func_scope.enclosing_scope # An instance or type that should have the ruby method declared

				# note: For static proxies on Types (like Record.find), create a temporary instance of the Ruby class. This allows the proxy method to access the Type's declarations.
				target = if instance_or_type.instance_of?(Ore::Type) && instance_or_type.name
					ruby_class = find_ruby_class_for_type instance_or_type
					if ruby_class
						temp_instance              = ruby_class.new instance_or_type.name
						temp_instance.declarations = instance_or_type.declarations
						# todo: Do static_declarations need to be copied over?
						temp_instance
					else
						instance_or_type
					end
				else
					instance_or_type
				end

				unless target.respond_to? proxy_method
					raise Ore::Missing_Ruby_Proxy_Declaration.new expr, self
				end

				result = target.send proxy_method, *func_scope.arguments

				# Auto-link instances created by proxy methods to their global types
				if result.is_a?(Ore::Instance) && result.enclosing_scope.nil?
					type_name = result.class.name.split('::').last
					link_instance_to_type result, type_name
				end

				result
			when 'start', 'start_server', 'server_up'
				server = interpret expr.expression
				unless server.is_a? Ore::Instance
					raise Ore::Invalid_Start_Directive_Argument.new(expr, self)
				end

				server.port   = Integer(server.get(:port) || Ore::Server::DEFAULT_PORT)
				server.routes = collect_routes_from_instance server
				servers << server

				start_server server # sets server thread, webrick server, etc
				server
			when 'shut_down', 'server_down'
				server = interpret expr.expression
				unless server.is_a? Ore::Instance
					raise Ore::Invalid_Start_Directive_Argument.new(expr, self)
				end

				stop_server server
				server
			when 'connect'
				database = interpret expr.expression
				database.create_connection!
				database

			when 'cd'
				# note: This can be destructive to the scope pushed.
				if expr.expression&.value == '..'
					pop_scope
				else
					target = interpret expr.expression
					if target
						push_scope target
					else
						raise Ore::Invalid_Directive_Usage.new(expr, self)
					end
				end
			when 'sleep' # @sleep <seconds>
				sleep interpret expr.expression
			when Ore::IMPORT_FILE_DIRECTIVE
				# Standalone load is interpreted into current scope by passing the scope into runtime#load_file
				filepath = interpret expr.expression
				load_file_into_scope filepath, stack.last
				# note: #load_file_into_scope returns the output but it's ignored. Assigning the value of a @load directive executes code in #interp_infix_expr
			else
				raise Ore::Invalid_Directive_Usage.new(expr, self)
			end
		end

		def interp_subscript expr
			if expr.expression.expressions.count > 1
				raise Ore::Too_Many_Subscript_Expressions.new(expr.expression, self)
			end

			receiver = maybe_instance interpret expr.receiver

			case receiver
			when Ore::Dictionary, Ore::Array
				key = interpret expr.expression.expressions.first
				receiver.proxy_get key
			when Ore::Nil
				# todo: What should happen when subscripting nil? A warning of some kind maybe?
				nil
			when Ore::String
				index = interpret expr.expression.expressions.first
				receiver.value[index]
			else
				raise Ore::Invalid_Subscript_Receiver.new(expr.receiver, self)
			end
		end

		def interp_struct expr, allow_spread: true
			types         = [] # per-member type object (or the raw value itself for unnamed members)
			values        = [] # per-member real value, nil when a named member has none
			names         = []
			single_member = allow_spread && expr.types.length == 1 # only a lone unnamed member spreads -- see below

			expr.types.each_with_index do |member, i|
				if expr.names[i]
					# note; Named member (e.g. `some_string: String`), the member's own identifier (`some_string`) is just a label, not something to look up; resolve its declared type instead. Named members are never spread: the name is always its namespace (`.structure.columns`), even when the value is itself a Struct.
					if member.type
						type_ref        = Ore::Identifier_Expr.new
						type_ref.lexeme = member.type
						types << interpret(type_ref)
						if member.member_default
							default_value = interpret(member.member_default)
							values << wrap_struct_string_value(member.member_default, default_value)
						else
							values << nil
						end
					else
						# Bare `name := value` member, no `: Type` annotation -- infer the member's declared type from the default's own runtime type, same as plain `:=` does everywhere else.
						default_value = interpret(member.member_default)
						types << find_in_stack(type_name_to_string(default_value))
						values << wrap_struct_string_value(member.member_default, default_value)
					end
					names << expr.names[i]
				else
					value = interpret member

					if single_member && value.is_a?(Ore::Struct)
						types.concat value.type_objects
						values.concat value.values
						names.concat value.names
					else
						types << value
						values << wrap_struct_string_value(member, value)
						names << nil
					end
				end
			end

			# Each member's "type" here is just its value's own inferred type name
			type_names = types.map { |value| type_name_to_string value }
			build_struct names, type_names, types, values
		end

		# A struct/member value built from a string literal gets wrapped into a real Ore::String carrying the literal's own `quotation_style`, instead of staying the bare Ruby string #interp_string normally returns. Member's to_s{;} (ore/member.ore) reads `.quotation_style` straight off the value to decide how to quote it for display.
		def wrap_struct_string_value source_expr, value
			return value unless source_expr.is_a?(Ore::String_Expr) && value.is_a?(::String)
			finish_intrinsic_instance Ore::String.new(value, source_expr.quotation_style), 'String'
		end

		def build_struct names, type_names, types, values
			struct_type = find_in_stack 'Struct'

			# The low-level Ore::Struct object is always built first and exactly the same way
			# regardless of `struct_type` -- it's what #type_objects/etc. read from, and every existing
			# member-matching call site depends on it being real.
			struct = Ore::Struct.new names, type_names, types, values

			unless struct_type.is_a? Ore::Type
				link_instance_to_type struct, 'Struct'
				return struct
			end

			struct.name            = struct_type.name
			struct.types           = struct_type.types
			struct.enclosing_scope = struct_type

			run_type_body_on_instance struct_type, struct

			{ 'names' => names, 'type_names' => type_names, 'types' => types, 'values' => values }.each do |key, list|
				array = Ore::Array.new list
				link_instance_to_type array, 'Array'
				struct.declarations[key] = array
			end

			member_type = find_in_stack 'Member'
			if member_type.is_a?(Ore::Type) && struct.has?('members')
				members = names.each_index.map do |i|
					member_display_type = names[i] ? types[i] : find_in_stack(type_names[i])
					member              = Ore::Member.new names[i], member_display_type, values[i]
					link_instance_to_type member, 'Member'
					member
				end

				members_array = Ore::Array.new members
				link_instance_to_type members_array, 'Array'
				struct.declarations['members'] = members_array
			end

			struct
		end

		# @param expr [Ore::Operator_Overload_Expr]
		def interp_operator_overload expr
			# expr attrs:  func_expr(Func_Expr)  fixity(Lexeme)  precedence(Int)  value(String)
			# This is setting up operators to be treated as regular functions, whose identifier is its operator symbols without spaces.

			stack.last.declare expr.value, interpret(expr.func_expr)
		end

		# note: This is the entry point for all expressions. This is called in a loop until all expressions are evaluated, or the program crashes.
		def interpret expr
			case expr
			when Ore::Number_Expr, Ore::Symbol_Expr
				expr.value

			when Ore::Identifier_Expr
				interp_identifier expr

			when Ore::String_Expr
				interp_string expr

			when Ore::Type_Expr
				interp_type expr

			when Ore::Route_Expr
				interp_route expr

			when Ore::Func_Expr
				interp_func expr

			when Ore::Func_Signature_Expr
				interp_func_signature expr

			when Ore::Composition_Expr
				interp_composition expr

			when Ore::Prefix_Expr
				interp_prefix expr

			when Ore::Nil_Init_Expr
				# This is a special infix expression `<ident>,` that desugars to `ident = ident or nil`. left is assigned nil if it doesn't exist, or is returned if it does
				interp_nil_init expr

			when Ore::Infix_Expr
				interp_infix expr

			when Ore::Postfix_Expr
				interp_postfix expr

			when Ore::Circumfix_Expr
				interp_circumfix expr

			when Ore::Call_Expr
				interp_call expr

			when Ore::For_Loop_Expr
				interp_for_loop expr

			when Ore::Conditional_Expr
				interp_conditional expr

			when Ore::Array_Index_Expr
				maybe_instance expr.indices_in_order

			when Ore::Subscript_Expr
				interp_subscript expr

			when Ore::Directive_Expr
				interp_directive expr

			when Ore::Fence_Expr
				interp_fence expr

			when Ore::Html_Fence_Expr
				interp_html_fence expr

			when Ore::Comment_Expr
				expr.value

			when Ore::Operator_Overload_Expr
				interp_operator_overload expr

			when Ore::Operator_Expr
				case expr.value
				when 'skip'
					throw :skip
				when 'stop'
					throw :stop
				end

			when Ore::Struct_Expr
				interp_struct expr

			else
				raise Ore::Interpret_Expr_Not_Implemented.new(expr, self)
			end
		end
	end
end
