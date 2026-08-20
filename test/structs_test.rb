require 'minitest/autorun'
require_relative '../src/ore'
require_relative 'base_test'

class Structs_Test < Base_Test
	def test_parses_standalone_struct_literal
		out = Ore.parse '<String, Number>'
		assert_kind_of Ore::Struct_Expr, out.first
		assert_equal %w(String Number), out.first.types.map(&:value)
	end

	def test_parses_standalone_struct_literal_with_single_type
		out = Ore.parse '<String>'
		assert_kind_of Ore::Struct_Expr, out.first
		assert_equal %w(String), out.first.types.map(&:value)
	end

	def test_parses_type_declaration_with_struct
		out = Ore.parse 'Array<String> {}'
		assert_kind_of Ore::Type_Expr, out.first
		assert_equal 'Array', out.first.name
		assert_kind_of Ore::Struct_Expr, out.first.structure
		assert_equal %w(String), out.first.structure.types.map(&:value)
	end

	def test_parses_type_declaration_with_multiple_members
		out = Ore.parse 'Dictionary<String, Number> {}'
		assert_equal %w(String Number), out.first.structure.types.map(&:value)
	end

	def test_type_declaration_without_struct_has_nil_struct
		out = Ore.parse 'String {}'
		assert_nil out.first.structure
	end

	def test_struct_members_can_be_arbitrary_expressions
		out = Ore.parse 'Abc<1+2+3/123>'
		assert_kind_of Ore::Infix_Expr, out.first.structure.types.first

		result = Ore.interp "Abc {}
		Abc<Number> {}
		Abc<1+2+3/123>.structure.types.first()"
		assert_equal 3, result
	end

	def test_interprets_standalone_struct_literal_to_struct_instance
		out = Ore.interp '<String, Number>'
		assert_kind_of Ore::Struct, out
		assert_equal 'String', out.type_objects[0].name
		assert_equal 'Number', out.type_objects[1].name
	end

	def test_struct_instance_types_accessible_from_ore
		out = Ore.interp "g := <String, Number>
		g.types"
		assert_equal 'String', out.values[0].name
		assert_equal 'Number', out.values[1].name
	end

	def test_bare_struct_assignable_and_storable
		# A bare annotation alone on its own line (no `=` on the same expression) is undeclared, same as any other annotation (`x: Number` alone behaves identically) — combine the annotation and assignment into one expression, which is how self-declaring annotations actually work today.
		out = Ore.interp 'thing: <String, Number> = <String, Number>
		thing.types.count'
		assert_equal 2, out
	end

	def test_type_with_struct_still_composes_normally
		refute_raises do
			out = Ore.interp 'Array<String> {}'
			assert_kind_of Ore::Type, out
			assert_equal 'Array', out.name
		end
	end

	def test_composing_builtin_type_with_struct_does_not_break_it
		out = Ore.interp <<~CODE
		    String<Dictionary> {}
		    s := String('hello')
		    s.upcase()
		CODE
		assert_equal 'HELLO', out
	end

	def test_struct_does_not_interfere_with_plain_type_declarations
		out = Ore.interp <<~CODE
		    Point {
		    	x, y,
		    	new { x, y;
		    		self.x = x
		    		self.y = y
		    	}
		    }
		    p := Point(3, 4)
		    (p.x, p.y)
		CODE
		assert_equal [3, 4], out.values
	end

	def test_annotation_form_captures_struct
		out = Ore.parse 'x: Abc<Number>'
		assert_kind_of Ore::Struct_Expr, out.first.type_struct
		assert_equal %w(Number), out.first.type_struct.types.map(&:value)
	end

	def test_bare_struct_annotation_with_no_type_name
		out = Ore.parse 'thing: <String, Number>'
		assert_kind_of Ore::Struct_Expr, out.first.type_struct
		assert_equal %w(String Number), out.first.type_struct.types.map(&:value)
	end

	def test_type_reference_with_struct_does_not_mutate_shared_type
		out = Ore.interp <<~CODE
		    Abc<Number> {}
		    Abc<String> {}
		    x := Abc<Number>
		    y := Abc<String>
		    (x.structure.types.first(), y.structure.types.first())
		CODE
		assert_equal 'Number', out.values[0].name
		assert_equal 'String', out.values[1].name
	end

	def test_type_reference_works_with_constants_too
		out = Ore.interp <<~CODE
		    Abc {
		    	val,
		    	new { v; self.val = v }
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
		    	new { v; self.val = v }
		    }
		    Abc<Number> {}
		    y := Abc<Number>
		    z := y
		    z(5).val
		CODE
		assert_equal 5, out
	end

	def test_struct_bound_onto_instance_before_new_runs
		out = Ore.interp <<~CODE
		    Abc<Number> {
		    	new {;}
		    }
		    z := Abc<4815>
		    zz := z()
		    zz.structure.types.first()
		CODE
		assert_equal 4815, out
	end

	def test_struct_members_are_not_forwarded_as_constructor_arguments
		out = Ore.interp <<~CODE
		    Abc {
		    	val,
		    	new { v := -1; self.val = v }
		    }
		    Abc<Number> {}
		    zz := Abc<4815>()
		    zz.val
		CODE
		assert_equal(-1, out)
	end

	def test_named_member_schema_parses_and_resolves_declared_type
		out = Ore.parse 'Type<some_string: String, num: Number> {}'
		assert_equal ['some_string', 'num'], out.first.structure.names

		type = Ore.interp 'Type<some_string: String, num: Number> {}'
		assert_equal 'String', type.structure_declaration.declarations['some_string'].name
		assert_equal 'Number', type.structure_declaration.declarations['num'].name
	end

	def test_structure_declaration_captures_default_values
		type = Ore.interp 'Widget<indent: Number = 2> {}'
		assert_equal ['indent'], type.structure_declaration.names
		assert_equal [2], type.structure_declaration.values
	end

	def test_unstructured_declaration_has_no_structure_declaration
		type = Ore.interp 'Plain { x, }'
		assert_nil type.structure_declaration
	end

	def test_structure_declaration_is_independent_per_variant
		out = Ore.interp <<~CODE
		    dict_variant := String<dict: Dictionary> {}
		    num_variant := String<num: Number> {}
		    (dict_variant, num_variant)
		CODE
		dict_variant, num_variant = out.values

		assert_equal ['dict'], dict_variant.structure_declaration.names
		assert_equal 'Dictionary', dict_variant.structure_declaration.type_objects.first.name

		assert_equal ['num'], num_variant.structure_declaration.names
		assert_equal 'Number', num_variant.structure_declaration.type_objects.first.name
	end

	def test_structure_declaration_equal_compares_names_and_types
		dict_a = Ore::Struct.new(['dict'], ['Dictionary'], [nil])
		dict_b = Ore::Struct.new(['dict'], ['Dictionary'], [nil])
		other  = Ore::Struct.new(['other'], ['Dictionary'], [nil]) # same type, different name
		number = Ore::Struct.new(['dict'], ['Number'], [nil]) # same name, different type

		assert dict_a.structure_declaration_equal?(dict_b)
		refute dict_a.structure_declaration_equal?(other)
		refute dict_a.structure_declaration_equal?(number)
	end

	# Reference matching (`String<{x=1}>()`) never supplies member names, so it only ever compares
	# against `type_names` -- names exist purely to keep declarations distinct from each other.
	def test_structure_satisfied_by_candidates_ignores_names
		declared = Ore::Struct.new(['dict'], ['Dictionary'], [nil])

		assert declared.satisfied_by_candidates?([['Dictionary']])
		refute declared.satisfied_by_candidates?([['Number']])
	end

	def test_differently_named_same_typed_members_are_distinct_variants_regression
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

	def test_reference_to_never_declared_type_name_builds_a_bare_named_struct
		# `Ident<...>` with a base name that's never been declared as anything at all (no bare Type, no structured variant, no alias) isn't an error -- it's a bare named struct, same shape as `<...>` but with `.name` set from the identifier. Only collides with something else declared -- a real Type with a mismatched structure, or an alias to a non-Type value -- does it still raise (see test_reference_to_mismatched_declared_structure_raises).
		out = Ore.interp <<~CODE
		    n := Named<Number>
		    n.name
		CODE
		assert_equal 'Named', out

		out = Ore.interp <<~CODE
		    n := Named<Number>
		    n.types.values.map({it; it.name}).join(', ')
		CODE
		assert_equal 'Number', out
	end

	# Re-declaring the exact same bare named struct a second time used to raise Undeclared_Type_Structure -- `aliased` (the struct from the first declaration) being non-nil blocked the bare-named-struct fallback, even though the shape hadn't actually changed.
	def test_redeclaring_same_bare_named_struct_is_a_no_op
		refute_raises do
			out = Ore.interp <<~CODE
			    Task <
			    	id: Number
			    	done := false
			    >
			    Task <
			    	id: Number
			    	done := false
			    >
			    Task.name
			CODE
			assert_equal 'Task', out
		end
	end

	# A genuinely different shape under the same name still raises, unchanged.
	def test_redeclaring_bare_named_struct_with_a_different_shape_still_raises
		assert_raises Ore::Undeclared_Type_Structure do
			Ore.interp <<~CODE
			    Task <id: Number>
			    Task <id: String>
			CODE
		end
	end

	# A name, not position, identifies a named member everywhere it's actually used -- reordering named members is still the same declaration, not a different one.
	def test_redeclaring_bare_named_struct_with_reordered_members_is_a_no_op
		out = Ore.interp <<~CODE
		    Task <id: Number, done: Bool>
		    Task <done: Bool, id: Number>
		    Task.name
		CODE
		assert_equal 'Task', out
	end

	# Not just "doesn't raise" -- the actual member set is unchanged by the reorder, before and after.
	def test_redeclaring_bare_named_struct_with_reordered_members_keeps_the_same_members
		out = Ore.interp <<~CODE
		    before := Task <id: Number, done: Bool>
		    after := Task <done: Bool, id: Number>
		    (before.names, before.type_names, after.names, after.type_names)
		CODE
		before_members = out.values[0].values.zip(out.values[1].values).sort
		after_members  = out.values[2].values.zip(out.values[3].values).sort

		assert_equal [%w(done Bool), %w(id Number)], before_members
		assert_equal before_members, after_members
	end

	# Unnamed members have no such identity besides position -- reordering those still counts as a different structure and raises, same as any other shape mismatch.
	def test_redeclaring_unnamed_structured_type_with_reordered_members_still_raises
		assert_raises Ore::Undeclared_Type_Structure do
			Ore.interp <<~CODE
			    Abc<Number, String> {}
			    Abc<String, Number>
			CODE
		end
	end

	def test_reference_to_mismatched_declared_structure_raises
		assert_raises Ore::Undeclared_Type_Structure do
			Ore.interp <<~CODE
			    Abc<Number> {}
			    Abc<String>
			CODE
		end
	end

	# Undeclared_Type_Structure's own message-rendering used to crash (NoMethodError inside Struct_Expr#to_s) when the mismatched struct had a named member with no `: Type` annotation (`done := false` -- `.type` is nil, unlike `.type.value` this code blindly read). assert_raises here would surface that NoMethodError instead of the real error if this regressed.
	def test_mismatched_structure_error_message_renders_untyped_member_without_crashing
		error = assert_raises Ore::Undeclared_Type_Structure do
			Ore.interp <<~CODE
			    Task <id: String>
			    Task <
			    	id: Number
			    	done := false
			    >
			    CODE
		end
		assert_includes error.message, 'done: false'
	end

	def test_reference_matches_structure_by_composed_type_not_just_own_name
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

	def test_structured_type_can_be_aliased_and_restructured_through_the_alias
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

	def test_multi_member_reference_matches_via_composed_types_in_combination
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

	def test_unnamed_member_value_that_is_a_struct_spreads_into_the_struct
		type = Ore.interp <<~CODE
		    DEFAULT_COLUMNS := <id: Number, created_at: Number>
		    Thing<DEFAULT_COLUMNS> {}
		CODE
		assert_equal %w(id created_at), type.structure_declaration.names
		assert_equal %w(Number Number), type.structure_declaration.type_objects.map(&:name)
	end

	def test_spread_struct_members_bind_correctly_at_construction
		out = Ore.interp <<~CODE
		    DEFAULT_COLUMNS := <id: Number, created_at: Number>
		    Thing<DEFAULT_COLUMNS> {}

		    t := Thing<5, 1234>()
		    (t.structure.id, t.structure.created_at)
		CODE
		assert_equal [5, 1234], out.values
	end

	def test_reference_to_struct_valued_identifier_does_not_spread_regression
		out = Ore.interp <<~CODE
		    Options := <table_name: String, columns: Number>

		    Thing<opts: Options = Options> {
		    	new {;}
		    }

		    a := Thing<opts: Options>()
		    b := Thing<Options>()
		    (a.structure.opts, b.structure.opts)
		CODE
		refute_nil out.values[0]
		refute_nil out.values[1]
	end

	# Regression: a reference member named via the bare `:=` idiom (used to disambiguate an
	# otherwise-ambiguous match, e.g. `String<other := {x=1}>()`) bound the member's own *resolved
	# type* onto `.structure` instead of the real supplied value -- `interp_type`'s reference-resolution
	# read `supplied.type_objects` (identity-only, used for the "did they just restate the type"
	# check) where it should have read `supplied.values` for the actual result.
	def test_named_reference_member_preserves_the_real_supplied_value_regression
		out = Ore.interp <<~CODE
		    Data_Conn { name, new { name; self.name = name } }
		    Table<columns: Struct, database: Data_Conn> {}

		    cols := <name: String, age: Number>
		    db := Data_Conn('primary')

		    t := Table<columns := cols, database := db>
		    (t.structure.columns.names, t.structure.database.name)
		CODE
		assert_equal %w(name age), out.values[0].values
		assert_equal 'primary', out.values[1]
	end

	def test_redeclaring_same_structure_extends_the_same_variant
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

	# A structured type declaration never bound its own bare name in @declarations the way a bare `Type { }` does -- only `Abc<Number>()` (a full reference) resolved it. When exactly one variant is declared under a name, the bare name is unambiguous, so it's reachable too now.
	def test_structured_type_reachable_by_bare_name_when_unambiguous
		out = Ore.interp <<~CODE
		    Abc<Number> {
		    	greet {; 'hi' }
		    }
		    x := Abc()
		    x.greet()
		CODE
		assert_equal 'hi', out
	end

	# A genuinely ambiguous name (2+ declared variants) still can't resolve on its own -- there'd be no way to know which variant a bare `X()` should build.
	def test_structured_type_bare_name_stays_unreachable_when_ambiguous
		assert_raises Ore::Undeclared_Identifier do
			Ore.interp <<~CODE
			    X<a: Number> {}
			    X<b: String> {}
			    X()
			CODE
		end
	end

	def test_string_structured_with_a_dictionary
		src = <<~CODE
		    String<dict: Dictionary> {
		    	new { str: String = "";
		    		value = str
		    	}
		    	to_s {;
		    		final := value
		    		final += "{"
		    		for structure.dict
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

	# Member#to_s used to check `if value`/`elif not value` (truthy) to mean "has a value" -- `false` is a legitimate value that's also falsy in Ore, so a member holding it looked exactly like one holding nothing at all (`<done: Bool>` instead of `<done: Bool = false>`).
	def test_member_display_shows_a_real_false_value_not_as_unset
		out = Ore.interp '<done := false>.to_s()'
		assert_equal '<done: Bool = false>', out
	end

	def test_bare_default_member_infers_type_from_value
		out = Ore.interp '<id := 4815>'
		assert_equal ['id'], out.names
		assert_equal ['Number'], out.type_names
		assert_equal [4815], out.values
	end

	def test_structured_reference_has_members_populated
		out = Ore.interp <<~CODE
		    @load 'ore/struct.ore'
		    Abc<dict: Dictionary> {
		    	new {;}
		    }
		    z := Abc<{x=1}>
		    zz := z()
		    zz.structure.members
		CODE
		assert_equal 1, out.values.length
		assert_equal 'dict', out.values.first.name
	end

	def test_members_array_stays_positionally_aligned_with_unnamed_members
		out = Ore.interp <<~CODE
		    @load 'ore/struct.ore'
		    s := <name: String, Number>('Alice', 42)
		    s.members
		CODE
		assert_equal 2, out.values.length
		assert_equal 'name', out.values[0].name
		# .value is wrapped (Ore::String, carrying quotation_style) -- .value.value unwraps to the raw content.
		assert_equal 'Alice', out.values[0].value.value
		assert_nil out.values[1].name
		assert_equal 42, out.values[1].value
	end

	def test_bare_struct_literal_with_computed_value_parses
		assert_kind_of Ore::Struct, Ore.interp('<123>')
		assert_equal [3], Ore.interp('<1+2+3/123>').values
		assert_equal [3], Ore.interp('x := <1+2+3/123>
			x').values
	end

	# `for` over a Struct iterates its `.members` (Ore::Member instances, populated via `ore/struct.ore`, loaded by default) -- regression: used to call a nonexistent method and raise NoMethodError unconditionally.
	def test_for_loop_over_struct_iterates_members
		out = Ore.interp <<~CODE
		    s := <name: String, age: Number>('Alice', 30)
		    names := for s map
		        it.name
		    end
			names
		CODE
		assert_equal ['name', 'age'], out.values

		# With the standard library not loaded at all, a bare Struct has no `.members` to read (`ore/struct.ore` never ran) -- iterates zero elements rather than raising.
		refute_raises do
			out = Ore.interp(<<~CODE, load_standard_library: false)
			    s := <1, 2, 3>
			    count := 0
			    for s
			    	count += 1
			    end
				count
			CODE
			assert_equal 0, out
		end
	end

	# A struct member's only two named forms are `name: Type` and `name := value` -- there's no general `name: value` the way Dictionaries have. A lowercase value right after `:` used to be silently accepted: #parse_identifier_expr's own `: Type` lookahead declined to consume the `:` (since a lowercase identifier can never be a type), leaving it for the next loop iteration to reparse as an unrelated `:symbol` prefix literal -- `<columns: cols>` silently became the two elements `columns, :cols` instead of raising anywhere.
	def test_lowercase_value_after_colon_in_struct_raises
		assert_raises Ore::Invalid_Struct_Member_Annotation do
			Ore.interp 'columns := 99
				<columns: cols>'
		end
	end

	# The two legitimate ways to read as "two elements" instead: an explicit comma, or `:=` to actually give a member a value.
	def test_struct_still_supports_the_forms_that_look_similar
		out = Ore.interp 'columns := 99
			<columns, :cols>'
		assert_equal [99, :cols], out.values

		out = Ore.interp 'cols := <name: String>
			<columns := cols>'
		assert_kind_of Ore::Struct, out.values.first
	end

	def test_struct_typed_param_parses
		out = Ore.parse 'f { right: <name: String, type: Any, value: Any>; right }'
		param = out.first.parameters.first
		assert_kind_of Ore::Struct_Expr, param.type_struct
		assert_equal %w(name type value), param.type_struct.names
		assert_equal %w(String Any Any), param.type_struct.types.map { |member| member.type.value }
	end

	def test_struct_typed_param_accepts_structurally_compatible_argument
		refute_raises do
			out = Ore.interp "@load 'ore/member.ore'
				f { right: <name: String, type: Any, value: Any>; right.name }
				m := Member('x', String, 4)
				f(m)"
			assert_equal 'x', out
		end
	end

	def test_struct_typed_param_raises_for_missing_member
		error = assert_raises Ore::Type_Contract_Violation do
			Ore.interp 'f { right: <name: String, type: Any, value: Any>; right }
				f(nil)'
		end
		assert_equal '<name, type, value>', error.contract
	end

	def test_struct_typed_param_raises_for_wrong_member_type
		error = assert_raises Ore::Type_Contract_Violation do
			Ore.interp 'Thing { name := 4 }
				f { right: <name: String>; right }
				f(Thing())'
		end
		assert_equal 'String', error.contract
		assert_equal 'Number', error.actual
	end

	def test_struct_typed_param_any_matches_anything
		refute_raises do
			out = Ore.interp "f { right: <value: Any>; right.value }
				Thing { value := 4815 }
				f(Thing())"
			assert_equal 4815, out
		end
	end

	def test_struct_typed_param_works_on_operator_overloads
		refute_raises do
			out = Ore.interp "@load 'ore/member.ore'
				Thing {
					@operator ~ @infix { left, right: <name: String>; right.name }
				}
				t := Thing()
				t ~ Member('x', String, 4)"
			assert_equal 'x', out
		end

		assert_raises Ore::Type_Contract_Violation do
			Ore.interp "Thing {
				@operator ~ @infix { left, right: <name: String>; right.name }
			}
			t := Thing()
			t ~ nil"
		end
	end

	# A struct annotation with only unnamed members (`<String, Number>`, no names to check anything by) enforces nothing at all on a param -- there's no name on the argument to look up. Documenting the current, if surprising, behavior rather than letting it go unnoticed.
	def test_struct_typed_param_with_only_unnamed_members_enforces_nothing
		refute_raises do
			out = Ore.interp 'f { x: <String, Number>; x }
				f(nil)'
			assert_nil out
		end
	end

	# `x: Abc<Number>` (a named type plus a structure) parses the same way it already does for plain identifiers/variables.
	def test_named_type_plus_struct_param_parses
		out = Ore.parse 'f { x: Abc<Number>; x }'
		param = out.first.parameters.first
		assert_equal 'Abc', param.type.value
		assert_kind_of Ore::Struct_Expr, param.type_struct
		assert_equal 'Abc', param.type_struct.name
	end

	# --- `<>` immediately followed by `;`/`,` (no space) -- lexer regression ---

	def test_struct_close_immediately_followed_by_semicolon_lexes_correctly
		out = Ore.lex '<String>;'
		values = out.map(&:value)
		assert_includes values, '>'
		assert_includes values, ';'
		refute_includes values, '>;'
	end

	def test_struct_close_immediately_followed_by_comma_lexes_correctly
		out = Ore.lex '<String>,X'
		values = out.map(&:value)
		assert_includes values, '>'
		assert_includes values, ','
		refute_includes values, '>,'
	end
end
