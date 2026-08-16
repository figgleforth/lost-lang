module Ore
	class Parser
		attr_accessor :i, :input, :precedences

		def initialize input = []
			@precedences = PRECEDENCES.dup
			# Track these so that they can be considered during parse-time
			@custom_infix     = ::Set.new
			@custom_prefix    = ::Set.new
			@custom_postfix   = ::Set.new
			@custom_circumfix = ::Set.new
			@input            = input
			@i                = 0 # index of current lexeme
		end

		def input= value
			@input = value
			@i     = 0
		end

		def copy_location expr, from_lexeme_or_expr
			return expr unless from_lexeme_or_expr

			expr.l0          = from_lexeme_or_expr.l0
			expr.c0          = from_lexeme_or_expr.c0
			expr.l1          = from_lexeme_or_expr.l1
			expr.c1          = from_lexeme_or_expr.c1
			expr.source_file = from_lexeme_or_expr.source_file

			expr
		end

		def output
			scan_and_register_operator_overloads_before_parsing # This has to be done before parsing because overloaded operators have to set their precedence level, which if done at runtime would the behavior of #precedence_for that now depends on an updated prcedence table with new precedences added.

			expressions = []
			while lexemes?
				expressions << parse_expression
			end

			expressions.compact
		end

		def scan_and_register_operator_overloads_before_parsing
			# The pattern:    @    operator   {user_operator}   @   {fixity}   {precedence_integer}
			#                 t0   t1          user_operator    t3   fixity     prec
			input.each_cons(6) do |t0, t1, user_operator, t3, fixity, prec|
				next unless t0.value == '@' && t1.value == 'operator' && t3.value == '@'

				fixities = %w(infix prefix postfix circumfix)
				raise Operator_Overload_Fixity_Must_Be_One_Of.new(fixities) unless fixities.include? fixity.value

				@precedences[user_operator.value] = case prec.value
				when '{'
					# todo; Log a warning that precedence was omitted and a fallback is used.
					precedence_for user_operator.value
				else
					raise Operator_Overload_Precedence_Must_Be_Integer.new prec unless prec.type == :number
					prec.value.to_i
				end

				case fixity.value
				when 'infix' then @custom_infix << user_operator.value
				when 'prefix' then @custom_prefix << user_operator.value
				when 'postfix' then @custom_postfix << user_operator.value
				when 'circumfix' then @custom_circumfix << user_operator.value
				end
			end
		end

		# If the given operator doesn't exist then it returns Ore::DEFAULT_OPERATOR_PRECEDENCE which binds somewhere around the equality operators. See Ore::PRECEDENCES
		# Neat reference for precedences: https://rosettacode.org/wiki/Operator_precedence
		# @param operator [::String]
		# @return precedence [Integer]
		def precedence_for operator
			@precedences[operator] || DEFAULT_OPERATOR_PRECEDENCE
		end

		# input[i - 1]
		def prev_lexeme
			input[[i - 1, 0].max]
		end

		# input[i]
		def curr_lexeme
			input[i]
		end

		# input[i..]
		def remainder
			input[i..]
		end

		def lexemes?
			i < input.length
		end

		def reduce lexeme = %W(\n \r)
			eat while lexemes? && curr?(lexeme)
		end

		def reduce_newlines
			eat while lexemes? && curr?(:delimiter) && %W(\n \r).include?(curr_lexeme.value)
		end

		def curr? * sequence
			return false unless remainder && lexemes?
			return false if sequence.count > remainder.count

			slice = remainder.slice(0, sequence.count)
			slice.each_with_index.all? do |lexeme, index|
				expected = sequence[index]

				if expected.is_a?(Ore::Array) || expected.is_a?(::Array)
					expected.any? do |alt|
						lexeme.is(alt)
					end
				else
					lexeme.is(expected)
				end
			end
		end

		def peek ahead = 1
			raise 'Parser.input is nil' unless input

			index = ahead.clamp(0, input.count)
			input[i + index]
		end

		def peek_until lexeme = nil
			return remainder unless lexeme

			depth = 0
			remainder.take_while do |it|
				depth += 1 if it.value == '{'
				depth -= 1 if it.value == '}'

				stop = if lexeme.is_a? Ore::Lexeme
					it.is lexeme
				else
					it.value == lexeme
				end

				!(stop && depth <= 0)
			end
		end

		def peek_contains? contains, stop_at_lexeme = nil
			peek_until(stop_at_lexeme).any? do |t|
				t.is contains
			end
		end

		# idea: support sequence of elements where an element can be one of many, like the sequence [IdentifierToken, [:=, =]]
		def eat * sequence
			raise "tried to eat #{sequence} but out of lexemes" unless lexemes?

			if sequence.nil? || sequence.empty? || sequence.one?
				eaten = curr_lexeme
				if sequence&.one? && !eaten.is(sequence[0])
					raise "Parser#eat expected #{sequence[0].inspect} but ate #{eaten.value.inspect}"
				end
				@i    += 1
				return eaten
			end
		end

		# Currently `stride` doesn't support option to overlap elements
		#
		#   for <collection> [map/select/reject] [by <stride>]
		#   end
		#
		#   for items map by 2
		#       it #[items.0, items.1], [items.2, items.3], ...
		#   end
		#
		def parse_for_loop_expr
			it            = Ore::For_Loop_Expr.new
			it.lexeme     = eat 'for'
			it.collection = parse_expression

			if curr? Ore::FOR_VERBS and verb = eat
				it.type   = verb
				it.lexeme = verb
			end

			if curr? 'by' and eat 'by'
				it.stride = begin_expression
				# todo: Should I check that it's a number here?
			end

			reduce_newlines

			it.body = []
			until curr? 'end'
				it.body << parse_expression
				reduce_newlines
			end
			it.body = it.body.compact

			eat 'end'
			it
		end

		def parse_conditional_expr
			it            = Ore::Conditional_Expr.new
			it.type       = eat # One of %w(if while unless until)
			it.condition  = parse_expression
			it.when_true  = []
			it.when_false = []
			reduce_newlines

			# @clean

			until curr? %w(end else elif elsif elwhile elswhile)
				expr = parse_expression
				it.when_true << expr if expr
				reduce_newlines
			end

			if curr? %w(elif elsif elwhile elswhile)
				it.when_false = parse_conditional_expr

			elsif curr? %w(else) and eat
				until curr? 'end'
					expr = parse_expression
					it.when_false << expr if expr
					reduce_newlines
				end
				eat 'end'

			elsif curr? %w(} end)
				eat

			else
				# todo: errors.rb
				raise "\n\nYou messed your if/elif/else up\n"
			end
			it
		end

		def parse_circumfix_expr opening: '('
			start = curr_lexeme
			it    = Ore::Circumfix_Expr.new
			it.grouping = CIRCUMFIX_GROUPINGS[opening] or raise "parse_circumfix_expr unknown opening #{opening}"
			eat opening
			reduce_newlines
			closing = it.grouping[1]

			it.expressions = []
			until curr? closing
				# note; A bare identifier immediately followed by `,` is special-cased here rather than going through #parse_expression, same fix #parse_struct already needed for `<...>`: #begin_expression's nil-init dispatch would otherwise interfere.
				it.expressions << if curr?(ANY_IDENTIFIER, ',')
					parse_identifier_expr
				else
					parse_expression
				end
				break if curr? closing

				eat if curr? ','
				reduce_newlines
			end

			eat closing
			it.expressions = it.expressions.compact
			it
			copy_location it, start
		end

		def parse_func precedence = STARTING_PRECEDENCE
			named            = curr?(:identifier)
			start            = curr_lexeme
			func             = Ore::Func_Expr.new
			func.expressions = [] # Expression
			func.parameters  = [] # Param_Expr

			if curr?(:identifier) || curr?(SCOPE_OPERATORS)
				func.name = parse_identifier_expr
			end

			# note; A bare `identifier: { ... ;}` (no type between the colon and the brace) is the new self-declaring signature form (`double: {Number -> Number;}`) of a function. parse_identifier_expr only consumes the colon itself when it's followed by an actual `: Type`/`: <...>` (or Struct)
			eat ':' if curr? ':'

			func.lexeme = func.name&.lexeme
			eat '{'
			reduce_newlines

			until curr? Ore::FUNCTION_DELIMITER
				if curr? '->' and eat '->'
					# A function (named or anonymous) declaring its own return type inline, at the end of its param list: `{ a: Number -> Number; ... }`. Distinct from `identifier: Type { ... }`, which is a signature reference/alias, not an implementation declaring its own type.
					func.type = eat(:Identifier)
					next
				end

				param = Ore::Param_Expr.new

				if curr? Ore::UNPACK_OPERATOR
					eat Ore::UNPACK_OPERATOR
					param.unpack = true
				end

				if curr?(:Identifier) || curr?(:IDENTIFIER)
					# Bare type, no name — a real function param always starts with a lowercase identifier, so a bare Capitalized token here can only mean this is a signature-literal's param list, e.g. `{Number, Number -> Number;}`.
					param.type   = eat
					param.lexeme = param.type
				else
					if curr? :identifier, :identifier
						param.label = eat(:identifier)
						param.name  = eat(:identifier)
					else
						param.name = eat(:identifier)
					end
					param.lexeme = param.name

					if curr? ':'
						eat ':'
						param.type = eat(:Identifier)
					end

					if curr? ':='
						eat ':='
						param.default = parse_expression
					elsif param.type && curr?('=')
						# `:=` is only required when there's no `: Type` to declare it instead.
						eat '='
						param.default = parse_expression
					end
				end

				func.parameters << param
				eat if curr? ','
				reduce_newlines
			end

			eat Ore::FUNCTION_DELIMITER if curr? Ore::FUNCTION_DELIMITER
			reduce_newlines

			until curr? '}'
				func.expressions << parse_expression
				reduce_newlines
			end

			# func.expressions = func.expressions #.compact #.uniq # bug, The first Param is twice in the array, with the same object_id. Dedupe it for now. Figure out the real issue later.
			eat '}'

			has_real_body = func.expressions.any?

			# A declared return type with no real body (just params) is a signature-only declaration — either self-declaring under a name (`double: {Number -> Number;}`) or anonymous (`{Number, Number -> Number;}`). Every param slot in a signature must carry a type (there's no name to fall back on at call sites), so a named-but-untyped param here (`{a -> Number;}`) is malformed.
			if func.type && !has_real_body
				untyped_param = func.parameters.find { |param| param.type.nil? }
				raise Ore::Invalid_Func_Signature.new(untyped_param.name) if untyped_param

				sig        = Ore::Func_Signature_Expr.new
				sig.name   = func.name
				sig.type   = func.type
				sig.lexeme = func.lexeme
				sig.params = func.parameters
				return copy_location sig, start
			end

			copy_location func, start
		end

		def parse_struct
			return nil unless curr? '<'
			start = curr_lexeme
			Ore::Struct_Expr.new.tap do |it|
				it.lexeme = Ore::Lexeme.new :struct, '<>'
				it.types  = []
				it.names  = []
				eat '<'
				until curr? '>'
					# Each element is a full expression (`Number`, `4815`, `1+2+3/123`, `this`, ...). A named element (`some_string: String`) parses as an Identifier_Expr with #type set, via #parse_identifier_expr's existing `: Type` annotation handling.
					# A bare identifier directly followed by `,` (`<String, Number>`) is special-cased here rather than going through #parse_expression, because #begin_expression would otherwise mistake it for the nil-init idiom (`ident,` => `ident = ident or nil`), which is unrelated to struct members and only coincidentally shares the same shape.
					element = if curr?(ANY_IDENTIFIER, ',')
						parse_identifier_expr
					else
						parse_expression(precedence_for('<'))
					end

					# A named member can carry a default, either typed (`dict: Dictionary = {}`) or bare (`id := 4815`, type inferred from the default at interpret time -- see #interp_struct). Both `=` and `:=` bind looser than `precedence_for('<')`, so #parse_expression above already stopped right before either, leaving them for us here.
					if curr? ':='
						eat ':='
						element.member_default = parse_expression(precedence_for('<'))
					elsif element.is_a?(Ore::Identifier_Expr) && element.type && curr?('=')
						eat '='
						element.member_default = parse_expression(precedence_for('<'))
					end

					# A `:` still sitting here means #parse_identifier_expr's own `: Type` lookahead (above, inside `element`) saw a `:` but declined to consume it, because what followed wasn't a valid type -- almost always a lowercase value, as if `:` worked like a Dictionary's `key: value`. It doesn't in a struct member list, so raise here rather than silently leaving the `:` to be reparsed as an unrelated `:symbol` prefix literal starting a whole new element next iteration (commas are optional between struct members, same as any other list).
					raise Ore::Invalid_Struct_Member_Annotation.new(curr_lexeme) if curr? ':'

					it.types << element
					it.names << if element.is_a?(Ore::Identifier_Expr) && (element.type || element.member_default)
						element.value
					else
						nil
					end

					eat if curr? ','
				end
				closing = eat '>'

				# Manually tracking location insead of using `#copy_location`, because I want it to span all of "<....>
				it.c0          = start.c0
				it.l0          = start.l0
				it.c1          = closing.c1
				it.l1          = closing.l1
				it.source_file = start.source_file
			end
		end

		def parse_type_decl
			# todo; The | TYPE_COMPOSITION_OPERATOR is currently only working in #parse_type_decl. I can peek until end of line, if I see another | then it's a circumfix. However if there are more |s then maybe we can presume the expression type like this:
			#
			#   1 | = composition
			#   2 | = circumfix
			#   3+ odd probably  = composition
			#   3+ even probably = circumfix
			#
			#   :absolute_value_circumfix
			#

			start        = curr_lexeme
			it           = Ore::Type_Expr.new eat # one of valid_idents
			it.name      = it.lexeme.value
			valid_idents = %i(Identifier IDENTIFIER)
			is_type      = Helpers.type_identifier? it.name
			is_const     = Helpers.constant_identifier? it.name

			Ore.assert is_type || is_const, "Type names can only be Capitalized or UPPERCASE" # todo; proper error

			it.structure = parse_struct # returns nil if none was found

			# When no body and no composition chain follow e.g.
			#
			#   x: Abc<Number>
			#   y := Abc<Number>
			#   Abc<Number>()
			#   Abc<4815>()
			#
			# Then this is a reference to an existing type (optionally structured), not a declaration. `it.expressions` stays nil here so callers (like #interp_type) can tell this apart from a real, even if empty, `{}` body. Whatever follows (like a trailing `(...)` call) is picked up in #complete_expression, same as any other primary expression.
			unless curr?('{') || curr?(TYPE_COMPOSITION_OPERATORS, ANY_IDENTIFIER)
				return copy_location it, start
			end

			it.expressions = []

			until curr? '{'
				break unless curr?(TYPE_COMPOSITION_OPERATORS, ANY_IDENTIFIER)
				it.expressions << parse_composition_expr
			end

			unless curr? '{'
				# No body followed the composition chain (`Abc|Def`, `A & B`, ...) so this is a reference to an anonymous type built by applying the chain, not a declaration.
				it.anonymous_composition = true
				return copy_location it, start
			end

			eat '{'
			reduce_newlines

			until curr?('}')
				it.expressions << parse_expression
				reduce_newlines
			end

			it.expressions = it.expressions.compact

			eat '}'
			copy_location it, start
		end

		def parse_comment
			lexeme   = eat
			it       = Ore::Comment_Expr.new lexeme
			it.value = Ore::String_Expr.new lexeme
			it.body  = Ore::String_Expr.new lexeme
			it.type  = lexeme.type
			it
		end

		def parse_fence_expr
			start    = curr_lexeme
			lexeme   = eat
			it       = Ore::Fence_Expr.new lexeme
			it.value = Ore::String_Expr.new lexeme
			it.type  = lexeme.type # :fence by default
			copy_location it, start
			it
		end

		def parse_html_expr
			# TODO: :html_vs_type_expr
			start      = curr_lexeme
			it         = Ore::Html_Fence_Expr.new eat
			it.value   = Ore::String_Expr.new start
			it.body    = it.value
			it.element = it.lexeme
			copy_location it, start
		end

		def parse_composition_expr
			start         = curr_lexeme
			expr          = Ore::Composition_Expr.new
			expr.operator = eat(:operator)
			ident         = parse_identifier_expr

			while curr?('.') && peek.is(:Identifier)
				dot_op         = eat('.')
				right          = parse_identifier_expr
				infix          = Ore::Infix_Expr.new
				infix.left     = ident
				infix.operator = dot_op
				infix.right    = right
				copy_location infix, ident
				ident = infix
			end

			# A composed operand can itself be a structured type reference (`| Other<'users'>`), not just a bare type reference. Wrap it into a Type_Expr (mirroring #parse_type_decl's own reference form) so #interp_composition resolves it through the normal structured-type matching. Without this the trailing `<...>` is left unconsumed and #parse_type_decl's `until curr? '{'` loop spins forever re-checking the same token.
			if curr?('<') && ident.is_a?(Ore::Identifier_Expr)
				type_ref           = Ore::Type_Expr.new
				type_ref.name      = ident.value
				type_ref.structure = parse_struct
				copy_location type_ref, ident
				ident = type_ref
			end

			expr.identifier = ident
			expr
			copy_location expr, start
		end

		def parse_statement_expr
			Ore::Statement_Expr.new.tap do |it|
				eat '`'
				it.expression = parse_expression
				eat '`'
			end
		end

		def parse_identifier_expr
			start = curr_lexeme
			expr  = Ore::Identifier_Expr.new

			if curr? BUILTIN_OPERATOR and eat BUILTIN_OPERATOR
				expr.directive = true
			elsif curr? SCOPE_OPERATORS
				expr.scope_operator = parse_scope_operator
			end

			expr.lexeme  = eat
			expr.privacy = Ore.privacy_of_ident expr.value

			# 7/20/25, I'm storing the type as well, even though I haven't written any code to support types yet.

			if curr?(':', :Identifier)
				eat ':'
				expr.type        = eat(:Identifier)
				expr.type_struct = parse_struct # returns nil if none was found
			elsif curr?(':', '<')
				eat ':'
				expr.type_struct = parse_struct # bare struct annotation, e.g. `thing: <String, Number>`
			end

			expr.kind = Ore.type_of_identifier expr.value
			copy_location expr, start
		end

		def parse_scope_operator
			scope = eat

			if curr? SCOPE_OPERATORS
				# There should not be any more scope operators at this point. We've implicitly handled . and ..
				raise Ore::Invalid_Scope_Syntax.new curr_lexeme
			end

			scope
		end

		def parse_symbol_expr
			start = curr_lexeme
			eat ':'
			it = Ore::Symbol_Expr.new eat
			copy_location it, start
		end

		def parse_route_expr
			start       = curr_lexeme
			route_token = eat :route

			# Split "get://users/:id" => ["get", "users/:id"]
			parts       = route_token.value.split HTTP_VERB_SEPARATOR
			http_method = parts[0]
			path_string = parts[1] || ''

			# Extract parameter names from dynamic path segments. ":id/:action" => ["id", "action"]
			path_segments = path_string.split '/'
			param_names   = path_segments
			                .select { |segment| segment.start_with?(':') }
			                .map { |segment| segment[1..-1] } # Remove ':' prefix

			# Parse handler function (must follow route declaration).
			# todo: Consider being able to use an existing identifier in place of a function expression
			reduce_newlines
			expr = parse_expression

			# Validate: handler params must include all route params
			handler_params = if expr.is_a? Ore::Func_Expr
				expr.parameters.map(&:name).map(&:value)
			else
				[]
			end

			missing_params = param_names - handler_params
			# todo: Is this a case that needs to be handled?
			# unless missing_params.empty?
			# end

			route             = Ore::Route_Expr.new
			route.http_method = Ore::Identifier_Expr.new.tap do |expr|
				expr.value = http_method
				expr.kind  = :identifier
			end
			route.path        = path_string
			route.expression  = expr
			route.param_names = param_names

			route
			copy_location route, start
		end

		def parse_percent_literal_expr
			start = curr_lexeme

			eat # %
			kind = eat # PERCENT_LITERALS

			eat '('
			reduce_newlines

			# Items are parsed one bare token at a time rather than via #parse_expression -- a symbolic operator item like `+`/`-` is also a valid PREFIX operator, and `parse_expression` would happily reparse it as a prefix/infix expression that swallows the *next* item as its operand instead of treating it as its own standalone item (`%str(+ - ^)` collapsing into one nested Prefix_Expr instead of three separate items being the symptom).
			items = []
			until curr? ')'
				items << if curr? '`'
					parse_statement_expr
				elsif curr? :operator
					parse_operator_expr
				elsif curr? :number
					parse_number_expr
				elsif curr?(ANY_IDENTIFIER)
					parse_identifier_expr
				else
					# Anything else (a string literal, `[1, 2]`, ...) still has to consume at least one token here -- otherwise the cursor never advances and `until curr? ')'` spins forever. #parse_expression is just a general-purpose way to consume *something* so the caller's own validity check below can raise a clean Invalid_Percent_Literal_Expression instead.
					parse_expression
				end

				break if curr? ')'
				eat if curr? ','
				reduce_newlines
			end

			eat ')'

			percent_lit             = Ore::Percent_Literal_Expr.new # This extends Circumfix_Expr
			percent_lit.kind        = kind.value
			percent_lit.grouping    = '[]' # so that it interprets as an array later
			percent_lit.expressions = items

			valid_items = percent_lit.expressions.all? do |it|
				# Each of these can easily be converted to a string, so for now they're the only ones allowed.
				it.is_a?(Ore::Identifier_Expr) || it.is_a?(Ore::Number_Expr) || it.is_a?(Ore::Operator_Expr) || it.is_a?(Ore::Statement_Expr)
			end

			raise Ore::Invalid_Percent_Literal_Expression.new(percent_lit) unless valid_items

			copy_location percent_lit, start
		end

		def parse_operator_expr
			start = curr_lexeme
			# A method just for this might seem silly, but I thought the same when I decided #make_expr should be a giant method. This will help in the long run, and consistency is key to keeping this maintainable.

			operator_lexeme = eat(:operator)

			# Scope operators can't be followed by literals like numbers or strings
			if SCOPE_OPERATORS.include? operator_lexeme.value
				if curr? :number
					raise Ore::Invalid_Scope_Syntax.new
				elsif curr? :string
					raise Ore::Invalid_Scope_Syntax.new
				end
			end

			it = Ore::Operator_Expr.new operator_lexeme
			copy_location it, start
		end

		def parse_number_expr
			start       = curr_lexeme
			expr        = Ore::Number_Expr.new start
			expr.lexeme = eat(:number)
			if expr.lexeme.value.count('.') > 1
				expr                  = Ore::Array_Index_Expr.new expr.lexeme
				expr.indices_in_order = expr.lexeme.value.split '.'
				expr.indices_in_order = expr.indices_in_order.map &:to_i
				# It's important not to convert number.value here to anything to preserve the variant number of dots in the string. I think this'll be cool syntax, 2d_array.1.2 would be the equivalent of 2d_array[1][2].
			elsif expr.lexeme.value.include? '.'
				expr.type  = :float
				expr.value = expr.value.to_f
			else
				expr.type  = :integer
				expr.value = expr.value.to_i
			end
			expr
			copy_location expr, start
		end

		def parse_nil_init_expr
			start = curr_lexeme

			expr          = Ore::Nil_Init_Expr.new
			expr.lexeme   = start
			expr.left     = parse_identifier_expr
			expr.operator = Lexeme.new(:operator, '=')

			nil_expr         = Ore::Identifier_Expr.new
			nil_expr.value   = 'nil'
			nil_expr.kind    = :identifier
			nil_expr.privacy = Ore.privacy_of_ident 'nil'
			expr.right       = nil_expr

			copy_location expr, start
		end

		def begin_expression precedence = STARTING_PRECEDENCE
			raise Ore::Out_Of_Tokens.new unless lexemes?

			if curr? :route
				parse_route_expr

			elsif curr?(ANY_IDENTIFIER, Ore::NIL_INIT_POSTFIX) || curr?(SCOPE_OPERATORS, ANY_IDENTIFIER, Ore::NIL_INIT_POSTFIX)
				parse_nil_init_expr

			elsif peek_contains?(Ore::FUNCTION_DELIMITER, '}') && (curr?('{') || curr?(:identifier, '{') || curr?(:identifier, ':', '{') || curr?(SCOPE_OPERATORS, :identifier, '{') || curr?(SCOPE_OPERATORS, :identifier, ':', '{'))
				parse_func precedence

			elsif curr?('<') && curr_lexeme.type == :operator && !@custom_prefix.include?('<')
				# note; A leading `<` can never be a legitimate infix `<` so we can safely parse a struct.
				# The `curr_lexeme.type == :operator` guard matters: `curr?('<')` matches by lexeme VALUE
				# alone, so a string literal whose own content happens to be exactly "<" (e.g. `'<'`) used
				# to be misparsed as the start of a struct literal too, swallowing everything after it --
				# same bug class already fixed for prefix operators colliding with string content (see the
				# String_Expr exclusion a bit further down in this method).
				parse_struct

			elsif curr?(:Identifier, '{') || curr?(:Identifier, TYPE_COMPOSITION_OPERATORS) || curr?(:IDENTIFIER, TYPE_COMPOSITION_OPERATORS) || curr?(:IDENTIFIER, '{') || curr?(TYPE_IDENTIFIER, '<')
				parse_type_decl

			elsif curr?(TYPE_COMPOSITION_OPERATORS) && peek.is(:Identifier)
				parse_composition_expr

			elsif curr? 'for'
				parse_for_loop_expr

			elsif curr? %w(if while unless until)
				parse_conditional_expr

			elsif curr?(:identifier, ':', :Identifier) || curr?(ANY_IDENTIFIER) || curr?(SCOPE_OPERATORS, ANY_IDENTIFIER) || curr?(BUILTIN_OPERATOR, :identifier) || curr?(BUILTIN_OPERATOR, :Identifier) || curr?(BUILTIN_OPERATOR, :IDENTIFIER)
				parse_identifier_expr

			elsif curr?(%w( [ \( { |)) && curr?(:delimiter)
				# :absolute_value_circumfix
				parse_circumfix_expr opening: curr_lexeme.value

			elsif curr?(':', :identifier) || curr?(':', :Identifier) || curr?(':', :IDENTIFIER)
				parse_symbol_expr

			elsif curr? '%', PERCENT_LITERALS, '('
				parse_percent_literal_expr

			elsif curr? '`'
				parse_statement_expr

			elsif curr? :operator
				parse_operator_expr

			elsif curr? :number
				parse_number_expr

			elsif curr? :string
				start = curr_lexeme
				expr  = Ore::String_Expr.new eat(:string)
				copy_location expr, start

				# elsif curr? SCOPE_OPERATORS
				# 	parse_operator_expr

			elsif curr? ','
				# todo: Don't just discard the comma, make tuples implied when commas are found in #complete_expression
				eat and nil

			elsif curr? FUNCTION_DELIMITER
				# This is reserved for function declarations
				raise Ore::Reserved_Function_Delimiter.new curr_lexeme

			elsif curr? :delimiter
				reduce_newlines and nil

			elsif curr? :html # This is a subtype of Ore::Fence_Expr
				parse_html_expr

			elsif curr? :fence
				parse_fence_expr

			elsif curr? :comment
				parse_comment

			else
				raise "Unhandled lexeme: #{curr_lexeme.inspect}"
			end
		end

		def parse_expression precedence = STARTING_PRECEDENCE
			# 7/20/25, Unforunately, some other code depends on this being coupled with #complete_expression. That's okay for now, but lesson learned.
			#
			# 7/26/25, It's decoupled now but still kind of ugly. This is fine though, because it will allow me to handle any partial expressions. An example of a partial expression would be the code prior to an inline conditional:
			#
			#   /————\           <~ partial expression
			#   <code> if true
			#   \————————————/   <~ complete expression
			#

			expression = begin_expression precedence
			complete_expression expression, precedence
		end

		# todo: Factor out the various branches of code in here?
		def complete_expression expr, precedence = STARTING_PRECEDENCE
			return expr unless expr && lexemes?

			if expr.is_a?(Ore::Identifier_Expr) && expr.directive && expr.value != 'ruby'
				# note: I'm intentionally skipping `ruby` here because a Directive_Expr assumes an expression will follow it. But in the case of @ruby, I want it to be a standalone expression. Maybe this warrants rewriting how directives work? Or maybe this can just stay as an implementation detail. For now it's fine.
				directive      = Ore::Directive_Expr.new
				directive.name = expr
				copy_location directive, expr

				# Here I'm intercepting when an @operator directive is found, so that I can prebuild a special expression for operator overloads. Just FYI, this massive if body ends with a return statement,
				if expr.value == 'operator'
					op_lexeme            = eat # Eat the :operator or :identifier token directly. Going through parse_expression would apply custom fixity rules that are pre-registered and would misparse the operator in its own declaration.
					unless %i(operator identifier).include? op_lexeme.type
						raise "An operator can only by an :operator or :identifier. Your `#{op_lexeme.value}` is :#{op_lexeme.type}. Maybe it's reserved. todo; Better message!"
					end
					operator_expr        = Ore::Operator_Expr.new op_lexeme
					directive.expression = operator_expr
					copy_location operator_expr, op_lexeme

					# If @operator <Op_Expr> is followed by @infix <Num_Expr> then we have a complete operator overload expression
					next_expr = begin_expression
					if next_expr.is_a?(Ore::Identifier_Expr) && next_expr.directive
						if %w(prefix infix postfix circumfix).include? next_expr.value
							subdirective      = Ore::Directive_Expr.new
							subdirective.name = next_expr
							copy_location subdirective, next_expr

							subdirective.expression = if curr? '{'
								precedence_for(directive.expression.value)
							else
								e = parse_expression
								Ore.assert e.is_a?(Number_Expr)
								e.value
							end

							unless subdirective.expression.is_a? ::Numeric
								raise "an operator overload requires the following form:\n\n\t@operator <operator> @infix <precedence> {left, right; ...}\twhere <precedence> is optional."
							end

							# If you can't wrap your mind around this. At this point we know `@operator + @infix 90` so all that's left to parse is the function
							overload            = Ore::Operator_Overload_Expr.new operator_expr.lexeme
							overload.fixity     = subdirective.name.lexeme
							overload.precedence = subdirective.expression
							overload.func_expr  = parse_func
							overload.value      = operator_expr.lexeme.value

							return complete_expression overload, precedence
						end
					else
						return complete_expression next_expr, precedence
					end
				else
					directive.expression = parse_expression

					# note; Only `@assert cond, "message"` gets a trailing `, <expr>` parsed as part of the same directive (see Ore::Interpreter#interp_directive). This can't be generic across all directives: some fixtures chain unrelated directives on one line via `@load 'a', @load 'b'`, relying on a stray `,` here being silently discarded and the next statement.
					if expr.value == 'assert' && curr?(',')
						eat
						directive.message = parse_expression
					elsif expr.value == 'declare'
						# note; `@declare "ident", value, Type`
						directive.arguments = [directive.expression]
						while curr? ','
							eat
							directive.arguments << parse_expression
						end
					end
				end

				return complete_expression directive, precedence
			end

			if SCOPE_OPERATORS.any? { |it| expr.is it } && !expr.is_a?(Ore::Nil_Init_Expr)
				return expr
			end

			# note; `PREFIX.include?(expr.value)` matches by VALUE, not by lexeme type -- deliberate, since
			# keyword-like prefixes (`return`, `not`) are lexed as plain identifiers, not a dedicated
			# operator type, so there's no `.type == :operator` to check for those. But that means a
			# String_Expr whose own CONTENT happens to collide with a prefix symbol (`'!'`, `'-'`, a
			# string literally spelled `'return'`) matched too -- `"hi".end_with?('!')` parsed `'!'` as
			# the `!` prefix operator applied to nothing, not the string value "!". A string's content
			# should never be reinterpreted as an operator, so it's excluded here regardless of value.
			prefix    = !expr.is_a?(Ore::Operator_Overload_Expr) && !expr.is_a?(Ore::String_Expr) && (PREFIX.include?(expr.value) || (expr.is_a?(Ore::Operator_Expr) && @custom_prefix.include?(expr.value)))
			infix     = INFIX.include?(curr_lexeme.value) || @custom_infix.include?(curr_lexeme.value)
			postfix   = POSTFIX.include?(curr_lexeme.value) || @custom_postfix.include?(curr_lexeme.value)
			circumfix = CIRCUMFIX.include?(curr_lexeme.value)

			if prefix
				expr = Ore::Prefix_Expr.new.tap do |it|
					it.operator   = expr
					it.expression = parse_expression precedence_for(it.operator.value)
				end

				return complete_expression expr, precedence
			elsif infix
				if COMPOUND_OPERATORS.include? curr_lexeme.value
					### note: I seem to have forgotten this important check for precedence here. I'm sure there are other places todo
					curr_operator_prec = precedence_for curr_lexeme.value
					return expr if curr_operator_prec <= precedence
					###

					it          = Ore::Infix_Expr.new
					it.left     = expr
					it.operator = eat
					it.right    = parse_expression precedence_for it.operator.value
					it.right    = it.right.left if it.right.is_a? Ore::Nil_Init_Expr

					copy_location it, expr
					return complete_expression it, precedence
				elsif RANGE_OPERATORS.include? curr_lexeme.value
					it          = Ore::Infix_Expr.new
					it.left     = expr
					it.operator = eat
					it.right    = parse_expression
					it.right    = it.right.left if it.right.is_a? Ore::Nil_Init_Expr

					copy_location it, expr
					return complete_expression it, precedence
				else
					while (INFIX.include?(curr_lexeme.value) || @custom_infix.include?(curr_lexeme.value)) && curr?(:operator)
						# It's very important that the curr?(:operator) check here remains because otherwise it breaks Ore::Call_Expr when the receiver is an Ore::Infix_Expr.
						curr_operator      = curr_lexeme.value
						curr_operator_prec = precedence_for curr_operator

						if curr_operator_prec <= precedence
							return expr
						end

						left          = expr
						expr          = Ore::Infix_Expr.new
						expr.left     = left
						expr.operator = eat(curr_lexeme.value)
						expr.right    = parse_expression curr_operator_prec
						expr.right    = expr.right.left if expr.right.is_a? Ore::Nil_Init_Expr
						copy_location expr, left

						if expr.left.is(Ore::Identifier_Expr) && expr.operator.value == '.' && expr.right.is(Ore::Number_Expr) && expr.right.type == :float
							# @copypaste from above #parse_expression when :number.
							number                  = Ore::Array_Index_Expr.new expr.right
							number.indices_in_order = expr.right.value.to_s.split '.'
							number.indices_in_order = number.indices_in_order.map &:to_i
							expr.right              = number
						end

						return complete_expression expr, precedence
					end
				end

			elsif postfix && precedence_for(curr_lexeme.value) > precedence
				expr = Ore::Postfix_Expr.new.tap do |it|
					it.expression = expr
					it.operator   = eat(%i(operator identifier))
				end
			end

			call_expr = curr?('(') && curr?(:delimiter)
			subscript = curr? '['
			if call_expr && (precedence_for(curr_lexeme.value) > precedence)
				receiver       = expr
				fix            = parse_circumfix_expr opening: curr_lexeme.value
				expr           = Ore::Call_Expr.new
				expr.receiver  = receiver
				expr.arguments = fix.expressions

				copy_location expr, receiver
				return complete_expression expr, precedence
			elsif subscript && (precedence_for(curr_lexeme.value) > precedence)
				it            = Ore::Subscript_Expr.new
				it.receiver   = expr
				it.expression = parse_circumfix_expr opening: curr_lexeme.value
				it

				copy_location expr, left
				return complete_expression it, precedence
			end

			if curr?(%w(if while unless until))
				if precedence_for(curr_lexeme.value) <= precedence
					return expr
				end

				it            = Ore::Conditional_Expr.new
				it.when_true  = []
				it.when_false = []
				it.type       = eat # One of %w(if while unless until)
				it_prec       = precedence_for it.type.value
				it.condition  = parse_expression
				it.when_true  = [expr]
				return complete_expression it, precedence
			end

			expr
		end

	end
end
