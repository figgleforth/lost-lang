require 'minitest/autorun'
require_relative '../src/lost'
require_relative 'base_test'

class Pipeline_Test < Base_Test
	def test_interp
		assert_equal 42, Lost::Interpreter.new.run("42")
	end

	def test_lex
		result = Lost::Lexer.new("42").output
		assert_instance_of ::Array, result
		assert_instance_of Lost::Lexeme, result.first
	end

	def test_parse
		lexemes = Lost::Lexer.new("42").output
		result  = Lost::Parser.new(lexemes).output
		assert_instance_of ::Array, result
		assert_instance_of Lost::Number_Expr, result.first
	end

	def test_documenter
		code = <<~CODE
		    # a comment
		    1 + 1 # another comment
		CODE
		lexemes     = Lost::Lexer.new(code).output
		expressions = Lost::Parser.new(lexemes).output
		result      = Lost::Documenter.new(expressions).output
		assert_equal ['a comment', 'another comment'], result.map(&:value)
	end

	def test_type_checker
		lexemes     = Lost::Lexer.new("42").output
		expressions = Lost::Parser.new(lexemes).output
		assert_nil Lost::Type_Checker.new(expressions).output
	end
end
