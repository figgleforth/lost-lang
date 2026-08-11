require_relative 'error_formatter'

module Ore
	class Error < StandardError
		attr_accessor :expression, :runtime

		def initialize expression = nil, runtime = nil
			@expression = expression
			@runtime    = runtime
			super format_error
		end

		def format_error
			Error_Formatter.new(self, runtime).format
		end

		def detail_message
			nil
		end
	end

	class Undeclared_Identifier < Error
		# `expression` is whatever AST node was being resolved when lookup failed, usually an Ore::Identifier_Expr (a plain identifier reference), but also an Ore::Type_Expr when a bare type reference (`Abc()`) never got declared. Both expose `.value` via the shared Expression base (set from their own lexeme), so one implementation covers either raise site without caring which one it actually got.
		def detail_message
			name = expression.respond_to?(:value) ? expression.value : nil
			return nil unless name
			"#{Ascii.bold name} has not been declared"
		end
	end

	class Undeclared_Type_Shape < Error
		# When a tagged-type reference (`Abc<Number>`) has no declared variant matching its shape (`Abc<Number> {}`)
		# @expression: Ore::Type_Expr

		def detail_message
			name                 = expression.name
			shape                = expression.shape.to_s
			expected_shaped_type = "#{name}#{shape} {}"
			existing_type        = "#{name} {}"
			"#{Ascii.bold name} shaped with #{Ascii.bold shape} not found:\n\n\t#{Ascii.bold expected_shaped_type}"
		end
	end

	class Cannot_Reassign_Constant < Error
	end

	class Cannot_Assign_Incompatible_Type < Error
	end

	class Cannot_Assign_Undeclared_Identifier < Error
	end

	class Cannot_Initialize_Non_Type_Identifier < Error
	end

	class Invalid_Dictionary_Key < Error
	end

	class Invalid_Dictionary_Infix_Operator < Error
	end

	class Invalid_Dot_Infix_Left_Operand < Error
	end

	class Invalid_Dot_Infix_Right_Operand < Error
	end

	class Invalid_Unpack_Infix_Operator < Error
	end

	class Invalid_Unpack_Infix_Right_Operand < Error
	end

	class Unhandled_Prefix < Error
	end

	class Undeclared_Infix_Operator < Error
	end

	class Unhandled_Postfix < Error
	end

	class Missing_Argument < Error
	end

	class Assert_Triggered < Error
		attr_accessor :assertion_message

		def initialize expression = nil, runtime = nil, assertion_message = nil
			@assertion_message = assertion_message
			super expression, runtime
		end

		def detail_message
			assertion_message
		end
	end

	class Invalid_Http_Directive_Handler < Error
	end

	class Invalid_Start_Directive_Argument < Error
	end

	class Interpret_Expr_Not_Implemented < Error
		def detail_message
			"Interpreter does not handle `#{expression.inspect}` yet."
		end
	end

	class Out_Of_Tokens < Error
	end

	class Invalid_Scope_Syntax < Error
	end

	class Cannot_Use_Instance_Scope_Operator_Outside_Instance < Error
	end

	class Cannot_Use_Type_Scope_Operator_Outside_Type < Error
	end

	class Too_Many_Subscript_Expressions < Error
	end

	class Invalid_Subscript_Receiver < Error
	end

	class Cannot_Call_Private_Instance_Member < Error
	end

	class Cannot_Call_Instance_Member_On_Type < Error
	end

	class Cannot_Call_Private_Static_Member_On_Type < Error
	end

	class Invalid_Directive_Usage < Error
		# todo: This is not printing anything to stdouts
	end

	class Missing_Ruby_Proxy_Declaration < Error
	end

	class Invalid_Ruby_Proxy_Directive_Usage < Error
		# @ruby directive only supports function and variable declarations in the body of a Type declaration
	end

	class Invalid_Static_Directive_Declaration < Error
		# @static directive only supports function and variable declarations in the body of a Type declaration
	end

	class Unterminated_String_Literal < Error
	end

	class Lexed_Unexpected_Char < Error
		attr_accessor :expected, :got

		def initialize expected:, got:
			@expected = expected
			@got      = got
		end

		def detail_message
			"Expected `#{expected.inspect}`, got `#{got.inspect}`"
		end
	end

	class Lex_Char_Not_Implemented < Error
	end

	class Url_Not_Set_For_Database_Instance < Error
	end

	class Database_Not_Set_For_Table_Instance < Error
	end

	class Type_Checking_Failed < Error
		attr_accessor :errors

		def initialize errors
			@errors = errors
			super nil, nil
		end

		def format_error
			errors.map(&:message).join "\n"
		end
	end

	class Type_Mismatch < Error
		attr_accessor :declared, :inferred

		def initialize expression, declared, inferred
			@declared = declared
			@inferred = inferred
			super expression, nil
		end

		def detail_message
			"Expected #{declared}, got #{inferred}"
		end
	end

	class Reserved_Function_Delimiter < Error
	end

	class Type_Contract_Violation < Error
		attr_accessor :contract, :actual

		def initialize expression, contract, actual, interpreter
			@contract = contract
			@actual   = actual
			super expression, interpreter
		end

		def message
			"Type contract violation: expected #{@contract}, got #{@actual || 'unknown'}"
		end
	end

	class Operator_Overload_Fixity_Must_Be_One_Of < Error
	end

	class Operator_Overload_Precedence_Must_Be_Integer < Error
	end

	class Unsupported_Feature < Error
	end

	class Invalid_Func_Signature < Error
	end

	class Cannot_Call_Func_Signature < Error
		def detail_message
			args = expression.arguments.empty? ? '' : '...'
			"Did you mean to assign a function to `#{expression.receiver.value}` before calling `#{expression.receiver.value}(#{args})`?"
		end
	end

	class Unknown_Circumfix_Grouping < Error
	end

	class Arguments_Given_But_Not_Expected < Error
	end

	class Route_Param_Expected_But_Not_Found < Error
	end

	class Invalid_Composition_With_A_Non_Scope_type < Error
	end

	class Invalid_Composition_Operator < Error
	end

	class Argument_Label_Mismatch < Error
		attr_accessor :expected, :actual

		def initialize expression, expected, actual, runtime = nil
			@expected = expected
			@actual   = actual
			super expression, runtime
		end

		def detail_message
			expected_label = expected ? "#{expected}:" : 'no label'
			actual_label   = actual ? "#{actual}:" : 'no label'
			"Expected #{Ascii.bold expected_label}, got #{Ascii.bold actual_label}"
		end
	end

	class Invalid_Destructuring_Source < Error
		def detail_message
			'Only a Tuple or Shape can be destructured with `(...) := ...`'
		end
	end

	class Invalid_Destructuring_Target < Error
		def detail_message
			'Each destructuring target must be a plain identifier, e.g. `(a, b) := ...`'
		end
	end

	class Destructuring_Arity_Mismatch < Error
		attr_accessor :expected, :actual

		def initialize expression, expected, actual, runtime = nil
			@expected = expected
			@actual   = actual
			super expression, runtime
		end

		def detail_message
			"Tried to extract #{Ascii.bold expected.to_s} value#{'s' unless expected == 1}, but the source only has #{Ascii.bold actual.to_s}"
		end
	end
end
