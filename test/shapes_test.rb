require 'minitest/autorun'
require_relative '../src/ore'
require_relative 'base_test'

class Shapes_Test < Base_Test
	def test_parses_standalone_tags_literal
		out = Ore.parse '<String, Number>'
		assert_kind_of Ore::Shape_Expr, out.first
		assert_equal %w(String Number), out.first.types.map(&:value)
	end

	def test_parses_standalone_tags_literal_with_single_type
		out = Ore.parse '<String>'
		assert_kind_of Ore::Shape_Expr, out.first
		assert_equal %w(String), out.first.types.map(&:value)
	end

	def test_parses_type_declaration_with_tags
		out = Ore.parse 'Array<String> {}'
		assert_kind_of Ore::Type_Expr, out.first
		assert_equal 'Array', out.first.name
		assert_kind_of Ore::Shape_Expr, out.first.shape
		assert_equal %w(String), out.first.shape.types.map(&:value)
	end

	def test_parses_type_declaration_with_multiple_tags
		out = Ore.parse 'Dictionary<String, Number> {}'
		assert_equal %w(String Number), out.first.shape.types.map(&:value)
	end

	def test_type_declaration_without_tags_has_nil_tags
		out = Ore.parse 'String {}'
		assert_nil out.first.shape
	end

	def test_tag_fields_can_be_arbitrary_expressions
		out = Ore.parse 'Abc<1+2+3/123>'
		assert_kind_of Ore::Infix_Expr, out.first.shape.types.first

		result = Ore.interp "Abc {}
		Abc<Number> {}
		Abc<1+2+3/123>.shape.types.first()"
		assert_equal 3, result
	end

	def test_interprets_standalone_tags_literal_to_tags_instance
		out = Ore.interp '<String, Number>'
		assert_kind_of Ore::Shape, out
		assert_equal 'String', out.type_objects[0].name
		assert_equal 'Number', out.type_objects[1].name
	end

	def test_tags_instance_types_accessible_from_ore
		out = Ore.interp "g := <String, Number>
		g.types"
		assert_equal 'String', out.values[0].name
		assert_equal 'Number', out.values[1].name
	end

	def test_bare_tags_assignable_and_storable
		# A bare annotation alone on its own line (no `=` on the same expression) is undeclared, same as any other annotation (`x: Number` alone behaves identically) — combine the annotation and assignment into one expression, which is how self-declaring annotations actually work today.
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
		assert_kind_of Ore::Shape_Expr, out.first.type_tags
		assert_equal %w(Number), out.first.type_tags.types.map(&:value)
	end

	def test_bare_tags_annotation_with_no_type_name
		out = Ore.parse 'thing: <String, Number>'
		assert_kind_of Ore::Shape_Expr, out.first.type_tags
		assert_equal %w(String Number), out.first.type_tags.types.map(&:value)
	end

	def test_type_reference_with_tags_does_not_mutate_shared_type
		out = Ore.interp <<~CODE
		    Abc<Number> {}
		    Abc<String> {}
		    x := Abc<Number>
		    y := Abc<String>
		    (x.shape.types.first(), y.shape.types.first())
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
		    Abc<Number> {}
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
		    Abc<Number> {}
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
		    zz.shape.types.first()
		CODE
		assert_equal 4815, out
	end

	def test_tags_are_not_forwarded_as_constructor_arguments
		out = Ore.interp <<~CODE
		    Abc {
		    	val,
		    	new { v := -1; ./val = v }
		    }
		    Abc<Number> {}
		    zz := Abc<4815>()
		    zz.val
		CODE
		assert_equal(-1, out)
	end

	def test_named_tag_schema_parses_and_resolves_declared_type
		out = Ore.parse 'Type<some_string: String, num: Number> {}'
		assert_equal ['some_string', 'num'], out.first.shape.names

		type = Ore.interp 'Type<some_string: String, num: Number> {}'
		assert_equal 'String', type.shape_declaration.declarations['some_string'].name
		assert_equal 'Number', type.shape_declaration.declarations['num'].name
	end

	def test_shape_declaration_captures_default_values
		type = Ore.interp 'Widget<indent: Number = 2> {}'
		assert_equal ['indent'], type.shape_declaration.names
		assert_equal [2], type.shape_declaration.values
	end

	def test_untagged_declaration_has_no_shape_declaration
		type = Ore.interp 'Plain { x, }'
		assert_nil type.shape_declaration
	end

	def test_shape_declaration_is_independent_per_variant
		out = Ore.interp <<~CODE
		    dict_variant := String<dict: Dictionary> {}
		    num_variant := String<num: Number> {}
		    (dict_variant, num_variant)
		CODE
		dict_variant, num_variant = out.values

		assert_equal ['dict'], dict_variant.shape_declaration.names
		assert_equal 'Dictionary', dict_variant.shape_declaration.type_objects.first.name

		assert_equal ['num'], num_variant.shape_declaration.names
		assert_equal 'Number', num_variant.shape_declaration.type_objects.first.name
	end

	def test_shape_declaration_equal_compares_names_and_types
		dict_a = Ore::Shape.new(['dict'], ['Dictionary'], [nil])
		dict_b = Ore::Shape.new(['dict'], ['Dictionary'], [nil])
		other  = Ore::Shape.new(['other'], ['Dictionary'], [nil]) # same type, different name
		number = Ore::Shape.new(['dict'], ['Number'], [nil]) # same name, different type

		assert dict_a.shape_declaration_equal?(dict_b)
		refute dict_a.shape_declaration_equal?(other)
		refute dict_a.shape_declaration_equal?(number)
	end

	# Reference matching (`String<{x=1}>()`) never supplies field names, so it only ever compares
	# against `type_names` -- names exist purely to keep declarations distinct from each other.
	def test_shape_satisfied_by_candidates_ignores_names
		declared = Ore::Shape.new(['dict'], ['Dictionary'], [nil])

		assert declared.satisfied_by_candidates?([['Dictionary']])
		refute declared.satisfied_by_candidates?([['Number']])
	end

	def test_differently_named_same_typed_fields_are_distinct_variants_regression
		out = Ore.interp <<~CODE
		    String<dict: Dictionary> { to_s {; "dict-named" } }
		    String<other: Dictionary> { to_s {; "other-named" } }

		    a := String<{x=1}>()
		    a.to_s()
		CODE
		assert_equal 'dict-named', out

		out = Ore.interp <<~CODE
		    String<dict: Dictionary> { to_s {; "dict-named" } }
		    String<other: Dictionary> { to_s {; "other-named" } }

		    a := String<other := {x=1}>()
		    a.to_s()
		CODE
		assert_equal 'other-named', out

		out = Ore.interp <<~CODE
		    String<dict: Dictionary> { to_s {; "dict-named" } }
		    String<other: Dictionary> { to_s {; "other-named" } }

		    a := String<dict := {x=1}>()
		    a.to_s()
		CODE
		assert_equal 'dict-named', out
	end

	def test_reference_to_never_declared_shape_raises
		assert_raises Ore::Undeclared_Type_Shape do
			Ore.interp 'Abc<Number>'
		end
	end

	def test_reference_to_mismatched_declared_shape_raises
		assert_raises Ore::Undeclared_Type_Shape do
			Ore.interp <<~CODE
			    Abc<Number> {}
			    Abc<String>
			CODE
		end
	end

	def test_reference_matches_shape_by_composed_type_not_just_own_name
		out = Ore.interp <<~CODE
		    Flying { can_fly := true }
		    Duck | Flying { name := 'duck' }

		    String<val: Flying> {
		    	to_s {; "yes" }
		    }

		    d := Duck()
		    String<d>().to_s()
		CODE
		assert_equal 'yes', out
	end

	def test_tagged_type_can_be_aliased_and_retagged_through_the_alias
		out = Ore.interp <<~CODE
		    Flying { can_fly := true }
		    Duck | Flying { name := 'duck' }

		    String<val: Flying> {
		    	to_s {; "yes" }
		    }

		    duck := Duck()
		    Does_It_Fly := String<Flying>
		    Does_It_Fly<duck>().to_s()
		CODE
		assert_equal 'yes', out
	end

	def test_multi_field_reference_matches_via_composed_types_in_combination
		out = Ore.interp <<~CODE
		    Alpha { }
		    Beta { }
		    Combo_Alpha | Alpha { }
		    Combo_Beta | Beta { }

		    Thing<x: Alpha, y: Beta> {
		    	to_s {; "matched" }
		    }

		    Thing<Combo_Alpha(), Combo_Beta()>().to_s()
		CODE
		assert_equal 'matched', out
	end

	def test_unnamed_tag_value_that_is_a_shape_spreads_into_the_shape
		type = Ore.interp <<~CODE
		    DEFAULT_COLUMNS := <id: Number, created_at: Number>
		    Thing<DEFAULT_COLUMNS> {}
		CODE
		assert_equal %w(id created_at), type.shape_declaration.names
		assert_equal %w(Number Number), type.shape_declaration.type_objects.map(&:name)
	end

	def test_spread_shape_fields_bind_correctly_at_construction
		out = Ore.interp <<~CODE
		    DEFAULT_COLUMNS := <id: Number, created_at: Number>
		    Thing<DEFAULT_COLUMNS> {}

		    t := Thing<5, 1234>()
		    (t.shape.id, t.shape.created_at)
		CODE
		assert_equal [5, 1234], out.values
	end

	def test_reference_to_shape_valued_identifier_does_not_spread_regression
		out = Ore.interp <<~CODE
		    Options := <table_name: String, columns: Number>

		    Thing<opts: Options> {
		    	new {;}
		    }

		    a := Thing<opts: Options>()
		    b := Thing<Options>()
		    (a.shape.opts, b.shape.opts)
		CODE
		refute_nil out.values[0]
		refute_nil out.values[1]
	end

	def test_redeclaring_same_shape_extends_the_same_variant
		out = Ore.interp <<~CODE
		    Abc<Number> {
		    	first {; 'first' }
		    }
		    Abc<Number> {
		    	second {; 'second' }
		    }

		    a := Abc<Number>()
		    (a.first(), a.second())
		CODE
		assert_equal %w(first second), out.values
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
		    		for shape.dict
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

	def test_bare_default_field_infers_type_from_value
		out = Ore.interp '<id := 4815>'
		assert_equal ['id'], out.names
		assert_equal ['Number'], out.type_names
		assert_equal [4815], out.values
	end

	def test_tagged_reference_shape_has_fields_populated
		out = Ore.interp <<~CODE
		    @load 'ore/shape.ore'
		    Abc<dict: Dictionary> {
		    	new {;}
		    }
		    z := Abc<{x=1}>
		    zz := z()
		    zz.shape.fields
		CODE
		assert_equal 1, out.values.length
		assert_equal 'dict', out.values.first.name
	end

	def test_fields_array_stays_positionally_aligned_with_unnamed_fields
		out = Ore.interp <<~CODE
		    @load 'ore/shape.ore'
		    s := <name: String, Number>('Alice', 42)
		    s.fields
		CODE
		assert_equal 2, out.values.length
		assert_equal 'name', out.values[0].name
		# .value is wrapped (Ore::String, carrying quotation_style) -- .value.value unwraps to the raw content.
		assert_equal 'Alice', out.values[0].value.value
		assert_nil out.values[1].name
		assert_equal 42, out.values[1].value
	end

	def test_bare_shape_literal_with_computed_value_parses
		assert_kind_of Ore::Shape, Ore.interp('<123>')
		assert_equal [3], Ore.interp('<1+2+3/123>').values
		assert_equal [3], Ore.interp('x := <1+2+3/123>
			x').values
	end
end
