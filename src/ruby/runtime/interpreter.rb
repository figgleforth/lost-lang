require 'webrick'
require 'cgi'
require 'json'

module Ore
	class Interpreter
		attr_accessor :input, :lexer, :parser, :load_standard_library, :stack, :route_functions_by_route_name, :servers, :dom_onclick_function_handlers, :dom_input_elements, :cached_expressions_by_filepath, :cached_source_by_filename, :last_output

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
			if @stack.empty?
				global = Global.new
				if load_standard_library
					load_file_into_scope STANDARD_LIBRARY_PATH, global
				end
				@stack << global
			end
			@lexer.input  = source_code
			@parser.input = @lexer.output.reject do |lexeme|
				%I(comment).include? lexeme.type # The interpreter doesn't care about these
			end
			@input        = @parser.output # Expressions

			@last_output = output
			if servers.any?
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
						puts "Ore Server `#{server.server_instance.name}` started at http://localhost:#{server.port}"
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
			resolved_path = if filepath.start_with? 'ore/'
				File.join ROOT_PATH, filepath
			else
				File.expand_path filepath
			end

			push_scope into_scope

			unless @cached_expressions_by_filepath[resolved_path]
				code = File.read resolved_path
				register_source resolved_path, code
				@lexer.input                                   = code
				@parser.input                                  = @lexer.output
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
				scope             = Ore::Number.new expr
				scope.type        = Ore.type_of_number_expr expr
				scope.numerator   = expr
				scope.denominator = 1
				scope
			when ::String
				string = Ore::String.new expr
				link_instance_to_type string, 'String'
				string
			when ::Array
				array = Ore::Array.new expr
				link_instance_to_type array, 'Array'
				array
			when ::Hash
				dict = Ore::Dictionary.new expr
				link_instance_to_type dict, 'Dictionary'
				dict
			when nil
				Ore::Nil.shared
			when true
				Ore::Bool.truthy
			when false
				Ore::Bool.falsy
			else
				expr
			end
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
			!(value == nil || value == 0 || value == false) # todo? does this need to check truthiness of ore constructs?
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
			webrick = WEBrick::HTTPServer.new Port:      server.port,
			                                  Logger:    WEBrick::Log.new("/dev/null"),
			                                  AccessLog: []

			webrick.mount_proc '/onclick/' do |req, res|
				puts Ore::Ascii.dim "#{'DOM'.rjust(7, ' ')} #{req.path}"
				handle_request server, req, res
			end

			webrick.mount_proc '' do |req, res|
				handle_request server, req, res
			end

			server.webrick_server = webrick
			server.server_thread  = Thread.new { webrick.start }
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
					result = interp_route_body route_function, req, res, url_params, server_instance: server.server_instance

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
					type_name      = scope.class.name.split('::').last
					type_scope     = stack.reverse_each.find { |s| s.has?(type_name) }
					type_def       = type_scope[type_name] if type_scope
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
				else
					raise Ore::Undeclared_Identifier.new(expr, self)
				end
			else
				# When scope is nil, errors must be raised
				if expr.scope_operator&.value == '../'
					raise Ore::Cannot_Use_Type_Scope_Operator_Outside_Type.new(expr, self)
				elsif expr.scope_operator&.value == './'
					raise Ore::Cannot_Use_Instance_Scope_Operator_Outside_Instance.new(expr, self)
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
					result     = result.gsub "`#{sub}`", "#{value}"
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
				returned = interpret expr.expression
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

			# A type annotation (`x: Number = value`) is itself a declaration, so it's allowed to introduce a brand-new identifier just like `:=`, even though plain `=` otherwise requires the identifier to already exist. An inline signature (`x: Type{Param;} = value`) is the same idea — expr.left is a Func_Signature_Expr instead of a plain annotated Identifier_Expr, but it's just as self-declaring.
			has_type_annotation = (expr.left.is_a?(Ore::Identifier_Expr) && expr.left.type) ||
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

			# For plain identifiers (no scope operator) inside an Instance/Type body, new declarations should go to that Instance/Type, not to an enclosing scope that happens to have the same identifier. This fixes a bug that prevented HTML Layout's `title` from capturing Title's `title` declaration in examples/basic_html_page.ore.
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
				receiver = interpret expr.left.left
				property = expr.left.right

				check_dot_access_permissions! receiver, property.value, expr

				right_value              = interpret expr.right
				receiver[property.value] = right_value
				return right_value
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

		# @param expr [Ore::Infix_Expr]
		def interp_dot_infix expr
			return interp_dot_new expr if expr.right.is 'new'

			receiver = maybe_instance interpret expr.left

			unless receiver.kind_of?(Ore::Scope) || receiver.kind_of?(Ore::Range)
				raise Ore::Invalid_Dot_Infix_Left_Operand.new(expr, self)
			end

			case receiver
			when Ore::Array, Ore::Tuple
				interp_dot_array_or_tuple expr
			when Ore::Range
				interp_dot_range expr
			when Ore::Dictionary
				interp_dot_dictionary expr
			else
				# @copypaste from #interp_dot_scope because we already interpreted expr as 'left'. If #interp_dot_scope interprets expr again, we end up with duplicate duplicate instantiations

				if expr.right.instance_of? Ore::Type_Expr
					push_scope receiver
					result = interpret expr.right
					pop_scope
					return result
				end

				unless expr.right.instance_of? Ore::Identifier_Expr
					raise Ore::Invalid_Dot_Infix_Right_Operand.new(expr.right, self)
				end

				check_dot_access_permissions! receiver, expr.right.value, expr

				push_scope receiver

				# Here I'm special casing for `.?` which is my version of Ruby's `&.`
				result = case expr.operator.value
				when '.'
					interpret expr.right
				when '.?'
					begin
						interpret expr.right
					rescue Ore::Undeclared_Identifier
						nil
					end
				end
				pop_scope
				result
			end
		end

		def interp_dot_new expr
			receiver = interpret expr.left
			unless receiver.is_a? Ore::Type
				raise Ore::Cannot_Initialize_Non_Type_Identifier.new(expr.left, self)
			end

			instance             = Ore::Instance.new receiver.name # :generalize_me
			instance.expressions = receiver.expressions

			push_scope instance
			instance.expressions.each do |it|
				interpret it
			end
			pop_scope

			instance
		end

		def interp_dot_array_or_tuple expr
			scope = maybe_instance interpret expr.left

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
				interp_dot_scope expr
			end
		end

		def interp_dot_range expr
			range = interpret expr.left # maybe_instance interpret expr.left
			if expr.right.is(Ore::Func_Expr) && expr.right.name.value == 'each'
				interp_each_loop range, expr.right
			end
			range
		end

		def interp_dot_dictionary expr
			dict = maybe_instance interpret expr.left

			if expr.right.is_a? Ore::Identifier_Expr
				key_sym = expr.right.value.to_sym
				if dict.hash.has_key?(key_sym)
					return dict.hash[key_sym]
				end
			end

			# todo: Handle the case when dictionary keys shadow one of the builtin dictionary functions. Ideally check the dict scope first, then dict.hash, but manually check the scope instead of using #interpret because #interpret will look up the stack so the identifier may be found and evaluated despite not existing in dictionary.dict or dictionary the built-in.
			push_scope dict
			result = interpret expr.right
			pop_scope

			result
		end

		def interp_dot_scope expr
			scope = maybe_instance interpret expr.left

			raise Ore::Invalid_Dot_Infix_Left_Operand.new(expr, self) if scope.nil?
			raise Ore::Invalid_Dot_Infix_Right_Operand.new(expr.right, self) unless expr.right.instance_of? Ore::Identifier_Expr

			check_dot_access_permissions! scope, expr.right.value, expr

			push_scope scope
			result = interpret expr.right
			pop_scope
			result
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

		# @param expr [Ore::Infix_Expr]
		def interp_infix expr
			case expr.operator.value
			when '='
				interp_infix_assignment expr
			when ':='
				interp_infix_declaration expr
			when '.', '.?'
				interp_dot_infix expr
			else
				# We're checking for operator overloads first, then the default operator functionality is the fallback. Operator overloads are normal functions that take its operands as arguments, declared on the stack. We're looking them up as if they were regular named functions.
				overload_func = stack.reverse_each.find do |s|
					s.has? expr.operator.value
				end&.get(expr.operator.value)

				if overload_func.is_a? Ore::Func
					call           = Ore::Call_Expr.new
					call.arguments = [expr.left, expr.right]
					return interp_func_body overload_func, call
				end

				# note; Huge case/when each of which is the last value returned by this method, so basically a big return switch
				if expr.left.value == Ore::BUILTIN_OPERATOR # todo: Choose a different name for this, and a different character to use. @ is now gonna be exclusively "builtin" operator.
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
				elsif INFIX_ARITHMETIC_OPERATORS.include? expr.operator.value
					left  = maybe_instance interpret expr.left
					right = maybe_instance interpret expr.right

					# If left (or left's type) declares this operator via @operator, call it like a regular function with (left, right) as arguments. Falls back to left.enclosing_scope (the Type) because shorthand-constructed instances (array/string/dict literals, e.g. `[1, 2, 3]`) never get the type's own declarations copied down onto themselves the way `Array(...)`-style construction does (see #interp_type_call) -- this mirrors the same fallback #interp_identifier already does for regular method calls like `arr.push(...)`.
					overload_func = if left.is_a?(Ore::Scope) && left.has?(expr.operator.value)
						left.get expr.operator.value
					elsif left.is_a?(Ore::Scope) && left.enclosing_scope.is_a?(Ore::Type) && left.enclosing_scope.has?(expr.operator.value)
						left.enclosing_scope.get expr.operator.value
					end

					if overload_func.is_a? Ore::Func
						call           = Ore::Call_Expr.new
						call.arguments = [expr.left, expr.right]
						interp_func_body overload_func, call
					else
						left.send expr.operator.value, right
					end

				elsif COMPARISON_OPERATORS.include? expr.operator.value
					# note; I'm special casing these because they don't behave like the traditional == and != in Ruby.
					left  = interpret expr.left
					right = interpret expr.right

					case expr.operator.value
					when '==='
						left.types == right.types
					when '=!='
						left.types != right.types
					when '=>='
						# Is expr.left a superset of expr.right
						right.types.all? do |type|
							left.types.include? type
						end
					when '=<='
						# Is expr.right a superset of expr.left
						left.types.all? do |type|
							right.types.include? type
						end
					when '=/='
						# They share absolutely no types
						!left.types.any? do |type|
							right.types.include? type
						end
					when '=~', '!~'
						# These behave just like Ruby's =~/!~: =~ returns the match index (or nil), !~ returns the boolean negation of a match.
						subject     = maybe_instance(left).value
						pattern     = maybe_instance(right).value
						match_index = subject =~ Regexp.new(pattern)

						expr.operator.value == '!~' ? match_index.nil? : match_index
					else
						left.send expr.operator.value, right
					end

				elsif COMPOUND_OPERATORS.include? expr.operator.value
					# (a += b)  ==>  (a = (a + b))
					# Compute the arithmetic operation directly
					base_op = expr.operator.value[..-2] # Trim the = from +=, -=, etc.
					left    = maybe_instance interpret expr.left
					right   = maybe_instance interpret expr.right
					result  = left.send base_op, right

					# Assign back to left side
					assignment_scope = scope_for_identifier expr.left
					assignment_scope.declare expr.left.value, result

				elsif RANGE_OPERATORS.include? expr.operator.value
					start  = interpret expr.left
					finish = interpret expr.right
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

				elsif LOGICAL_OPERATORS.include? expr.operator.value
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
			end
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
					Ore::Tuple.new 'Tuple' # todo: For now, I guess. What else should I do with empty parens?
				elsif expr.expressions.count == 1
					# note: Single expressions should be treated as though they were not inside parentheses so that algebraic expressions can be grouped using parentheses. If I wrap single expressions in a Tuple then I have to also unwrap them later for arithmetic operations.
					interpret expr.expressions.first
				else
					values       = expr.expressions.reduce([]) do |arr, expr|
						arr << interpret(expr)
					end
					tuple        = Ore::Tuple.new 'Tuple'
					tuple.values = values
					tuple
				end
			when '{}'
				expr.expressions.reduce(Ore::Dictionary.new) do |dict, it|
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
			else
				raise Ore::Unknown_Circumfix_Grouping.new(expr, self)
			end
		end

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

			case receiver
			when Ore::Route
				interp_func_body receiver.handler, expr

			when Ore::Func
				interp_func_body receiver, expr

			when Ore::Instance, Ore::Type
				interp_type_call receiver, expr

			when Ore::Func_Signature
				raise Ore::Cannot_Call_Func_Signature.new expr.receiver, self

			else
				raise Ore::Cannot_Initialize_Non_Type_Identifier.new expr.receiver, self
			end
		end

		def interp_type expr
			existing = stack.last.has?(expr.name.value) && stack.last[expr.name.value]
			type     = existing.is_a?(Ore::Type) ? existing : Ore::Type.new(expr.name.value)

			type.expressions     = (type.expressions || []) + expr.expressions
			type.enclosing_scope = stack.last

			ore_name = "Ore::#{expr.name.value}"
			defined  = expr.name.value[0] != '_' && Object.const_defined?(ore_name) # note; #const_defined? does not allow underscore as the first character, hence the underscore check.
			link_instance_to_type type, expr.name.value if defined

			type.types ||= []
			type.types << type.name
			type.types = type.types.uniq

			push_then_pop type do |scope|
				expr.expressions.each do |expr|
					interpret expr
				end
			end

			stack.last.declare type.name, type
			type
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
		def interp_type_call type, expr
			ruby_class = find_ruby_class_for_type type
			instance   = ruby_class ? ruby_class.new : Ore::Instance.new(type.name)

			instance.name            = type.name
			instance.types           = type.types
			instance.enclosing_scope = type

			# note: There was a bug here where I wasn't popping the instance after interpreting the type's expressions. That caused the #new function below (func_new) to not properly interpret arguments passed to it.
			# note: We push type.enclosing_scope first (when present) so sibling types declared in the same scope can be found during instantiation.
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
			stack.last.declare expr.name.value, signature if expr.name&.value
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

		def interp_func_body func, expr
			params = func.expressions.select do |expr|
				expr.is_a? Ore::Param_Expr
			end

			# Evaluate arguments in caller's scope (before pushing function scopes)
			arg_values = expr.arguments.map { |arg| interpret arg }

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

			route_key = if func.name&.value
				func.name.value
			else
				# Anonymous route with auto-generated key: "method:path"
				"#{route.http_method.value}:#{route.path}"
			end

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
							scope.declare 'at', new_at
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
			# I'm being very explicit with the "== true" checks of the condition. It's easy to misread this to mean that as long as it's not nil. While the distinction in this case may not matter (in Ruby), I still haven't decided how this language will handle truthiness.
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
						until condition == true
							iteration_proc.call
						end
					else
						while condition == true
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
				# The behavior of truthiness is not yet finalized.
				condition = interpret expr.condition
				body      = if condition == false || condition.nil?
					expr.when_true
				else
					expr.when_false
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
				body      = if condition == true
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
			when 'puts'
				value = interpret expr.expression
				puts value # note: Don't remove this like I did, it is supposed to print out. todo: Be able to set your own output stream
				value
			when 'assert'
				condition = interpret expr.expression
				raise Ore::Assert_Triggered.new(expr, self) unless condition
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
			when 'start'
				server_instance = interpret expr.expression
				unless server_instance.is_a? Ore::Instance
					raise Ore::Invalid_Start_Directive_Argument.new(expr, self)
				end

				server                 = Ore::Server.new
				server.server_instance = server_instance
				server.port            = Integer(server_instance.get(:port) || Ore::Server::DEFAULT_PORT)
				server.routes          = collect_routes_from_instance server_instance
				servers << server

				start_server server
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

			else
				pp expr
				raise Ore::Interpret_Expr_Not_Implemented.new(expr, self)
			end
		end
	end
end
