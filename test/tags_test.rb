require 'minitest/autorun'
require_relative '../src/ruby/ore'
require_relative 'base_test'

class Tags_Test < Base_Test
	def test_parses_standalone_tags_literal
		out = Ore.parse '<String, Number>'
		assert_kind_of Ore::Tags_Expr, out.first
		assert_equal %w(String Number), out.first.types.map(&:value)
	end

	def test_parses_standalone_tags_literal_with_single_type
		out = Ore.parse '<String>'
		assert_kind_of Ore::Tags_Expr, out.first
		assert_equal %w(String), out.first.types.map(&:value)
	end

	def test_parses_type_declaration_with_tags
		out = Ore.parse 'Array<String> {}'
		assert_kind_of Ore::Type_Expr, out.first
		assert_equal 'Array', out.first.name
		assert_kind_of Ore::Tags_Expr, out.first.tags
		assert_equal %w(String), out.first.tags.types.map(&:value)
	end

	def test_parses_type_declaration_with_multiple_tags
		out = Ore.parse 'Dictionary<String, Number> {}'
		assert_equal %w(String Number), out.first.tags.types.map(&:value)
	end

	def test_type_declaration_without_tags_has_nil_tags
		out = Ore.parse 'String {}'
		assert_nil out.first.tags
	end

	def test_tag_slots_can_be_arbitrary_expressions
		out = Ore.parse 'Abc<1+2+3/123>'
		assert_kind_of Ore::Infix_Expr, out.first.tags.types.first

		result = Ore.interp "Abc {}
		Abc<1+2+3/123>.tags.types.first()"
		assert_equal 3, result
	end

	def test_interprets_standalone_tags_literal_to_tags_instance
		out = Ore.interp '<String, Number>'
		assert_kind_of Ore::Tags, out
		assert_equal 'String', out.types[0].name
		assert_equal 'Number', out.types[1].name
	end

	def test_tags_instance_types_accessible_from_ore
		out = Ore.interp "g := <String, Number>
		g.types"
		assert_equal 'String', out.values[0].name
		assert_equal 'Number', out.values[1].name
	end

	def test_bare_tags_assignable_and_storable
		# A bare annotation alone on its own line (no `=` on the same expression) is undeclared,
		# same as any other annotation (`x: Number` alone behaves identically) — combine the
		# annotation and assignment into one expression, which is how self-declaring annotations
		# actually work today.
		out = Ore.interp 'thing: <String, Number> = <String, Number>
		thing.types.count'
		assert_equal 2, out
	end

	def test_type_with_tags_still_composes_normally
		refute_raises do
			out = Ore.interp 'Array<String> {}'
			assert_kind_of Ore::Type, out
			assert_equal 'Array', out.name
		end
	end

	def test_composing_builtin_type_with_tags_does_not_break_it
		out = Ore.interp <<~CODE
		    String<Dictionary> {}
		    s := String('hello')
		    s.upcase()
		CODE
		assert_equal 'HELLO', out
	end

	def test_tags_do_not_interfere_with_plain_type_declarations
		out = Ore.interp <<~CODE
		    Point {
		    	x, y,
		    	new { x, y;
		    		./x = x
		    		./y = y
		    	}
		    }
		    p := Point(3, 4)
		    (p.x, p.y)
		CODE
		assert_equal [3, 4], out.values
	end

	def test_annotation_form_captures_tags
		out = Ore.parse 'x: Abc<Number>'
		assert_kind_of Ore::Tags_Expr, out.first.type_tags
		assert_equal %w(Number), out.first.type_tags.types.map(&:value)
	end

	def test_bare_tags_annotation_with_no_type_name
		out = Ore.parse 'thing: <String, Number>'
		assert_kind_of Ore::Tags_Expr, out.first.type_tags
		assert_equal %w(String Number), out.first.type_tags.types.map(&:value)
	end

	def test_type_reference_with_tags_does_not_mutate_shared_type
		out = Ore.interp <<~CODE
		    Abc<Number> {}
		    x := Abc<Number>
		    y := Abc<String>
		    (x.tags.types.first(), y.tags.types.first())
		CODE
		assert_equal 'Number', out.values[0].name
		assert_equal 'String', out.values[1].name
	end

	def test_type_reference_works_with_constants_too
		out = Ore.interp <<~CODE
		    Abc {
		    	val,
		    	new { v; ./val = v }
		    }
		    Y := Abc<Number>
		    Y(9).val
		CODE
		assert_equal 9, out
	end

	def test_type_reference_can_be_reassigned_before_calling
		out = Ore.interp <<~CODE
		    Abc {
		    	val,
		    	new { v; ./val = v }
		    }
		    y := Abc<Number>
		    z := y
		    z(5).val
		CODE
		assert_equal 5, out
	end

	def test_tags_bound_onto_instance_before_new_runs
		out = Ore.interp <<~CODE
		    Abc<Number> {
		    	new {;}
		    }
		    z := Abc<4815>
		    zz := z()
		    zz.tags.types.first()
		CODE
		assert_equal 4815, out
	end

	def test_tags_are_not_forwarded_as_constructor_arguments
		out = Ore.interp <<~CODE
		    Abc {
		    	val,
		    	new { v := -1; ./val = v }
		    }
		    zz := Abc<4815>()
		    zz.val
		CODE
		assert_equal(-1, out)
	end

	def test_named_tag_schema_parses_and_resolves_declared_type
		out = Ore.parse 'Type<some_string: String, num: Number> {}'
		assert_equal ['some_string', 'num'], out.first.tags.names

		type = Ore.interp 'Type<some_string: String, num: Number> {}'
		assert_equal 'String', type.tags.declarations['some_string'].name
		assert_equal 'Number', type.tags.declarations['num'].name
	end

	def test_string_tagged_with_a_dictionary
		src = <<~CODE
		    String<dict: Dictionary> {
		    	new { str: String = "";
		    		value = str
		    	}
		    	to_s {;
		    		final := value
		    		final += "{"
		    		for tags.dict
		    			final += "`key`::`value`, "
		    		end
		    		final += "}"
		    	}
		    }
		    a := String<{x=0, y=1, z=2}>()
		    b := String<{x=0, y=1, z=2}>("My dict: ")
		    (a.to_s(), b.to_s())
		CODE
		out = Ore.interp src
		assert_equal '{x::0, y::1, z::2, }', out.values[0]
		assert_equal 'My dict: {x::0, y::1, z::2, }', out.values[1]
	end
end
