require 'minitest/autorun'
require_relative '../src/ore'
require_relative 'base_test'

class Regression_Test < Base_Test
	def test_greater_equals_regression
		out = Ore.interp '2+1 >= 1'
		assert out
	end

	def test_precedence_operation_regression
		src = Ore.interp '1 + 2 / 3 - 4 * 5'
		ref = Ore.interp '(1 + (2 / 3)) - (4 * 5)'
		assert_equal ref, src
		assert_equal -19, src
	end

	def test_infixes_regression
		Ore::COMPOUND_OPERATORS.each do |operator|
			code = "left #{operator} right"
			out  = Ore.parse(code)
			assert_kind_of Ore::Infix_Expr, out.first
		end
	end

	def test_dot_slashes_regression
		ds  = Ore.parse './abc'
		dds = Ore.parse '../def'
		assert_kind_of Ore::Identifier_Expr, ds.first
		assert_kind_of Ore::Identifier_Expr, dds.first

		assert_kind_of Ore::Identifier_Expr, ds.last
		assert_equal './', ds.last.scope_operator.value
		assert_equal 'abc', ds.last.value
	end

	def test_dot_slash_regression
		out = Ore.interp './x := 123'
		assert_equal 123, out
	end

	def test_look_up_tilde_slash_without_dot_slash_regression
		out = Ore.interp '~/x := 456
		x'
		assert_equal 456, out
	end

	def test_look_up_tilde_slash_with_dot_slash_regression
		out = Ore.interp '~/y := 789
		~/y'
		assert_equal 789, out
	end

	def test_dot_slash_within_infix_regression
		out = Ore.parse './x? := 123'
		assert_kind_of Ore::Infix_Expr, out.first
		assert_equal ':=', out.first.operator.value
		assert_equal 'x?', out.first.left.value
		assert_kind_of Ore::Identifier_Expr, out.first.left
		assert_equal './', out.first.left.scope_operator.value
	end

	def test_scope_operators_regression
		out = Ore.parse './this_instance'
		assert_kind_of Ore::Identifier_Expr, out.first
		assert_equal 1, out.count

		out = Ore.parse '../class_scope'
		assert_kind_of Ore::Identifier_Expr, out.first
		assert_equal 1, out.count
	end

	def test_assigning_false_value_regression
		out = Ore.interp 'how := false
		how'
		assert_equal false, out
	end

	def test_identifier_lookup_regression
		out = Ore.interp 'Ore {}, Ore'
		assert_instance_of Type, out
	end

	def test_instance_does_not_have_new_function_regression
		out = Ore.interp '
		Atom {
			new {;}
		}
		a := Atom()
		b := Atom.new()
		(a, b)'
		refute out.values.first.has? :new
		refute out.values.last.has? :new
	end

	def test_dot_new_initializer_regression
		out = Ore.interp 'Number {
			numerator := 8

			new { num;
				./numerator = num
			}
		}
		x := Number.new(15)
		x.numerator'
		assert_equal 15, out
	end

	def test_calling_member_functions
		out = Ore.interp '
		Number {
			numerator := -100

			new { num;
				./numerator = num
			}
		}
		x := Number(4)
		x.numerator'
		assert_equal 4, out
	end

	def test_dot_slash_regression
		out = Ore.interp '
		Box {
			kind := "NONE"

			new { new_kind;
				./kind = new_kind
			}

			to_s {;
				"`kind`-box"
			}
		}

		b1 := Box("Big")
		s1 := b1.to_s()
		b2 := Box("Small")
		s2 := b2.to_s()
		(b1, s1, b2, s2)
		'
		assert_instance_of Ore::Instance, out.values[0]
		assert_equal "Big-box", out.values[1]
		assert_equal "Small-box", out.values[3]
	end

	def test_identifier_lookup_regression
		out = Ore.interp "x := 123
		funk {;
			~/x + 2
		}
		funk()"
		assert_equal 125, out

		out = Ore.interp "y := 0
		add { amount_to_add := 1;
			~/y + amount_to_add
		}
		(a := add(4))

		(a, add(a * 2))"
		assert_equal [4, 8], out.values

		out = Ore.interp "y := 0
		add { amount_to_add := 1;
			y += amount_to_add
		}
		a := add(4)

		(y, a)"
		assert_equal [4, 4], out.values

		refute_raises Ore::Undeclared_Identifier do
			out = Ore.interp "
			Thing {
				id,
				name := 'Thingy'

				new { new_name := '', id := 123;
					./name = new_name
					./id = id
				}
			}

			t1 := Thing()
			t2 := Thing('Thingus', 456)

			(t1.id, t1.name, t2.id, t2.name)"
			assert_equal [123, "", 456, "Thingus"], out.values
		end

		assert_raises Ore::Missing_Argument do
			out = Ore.interp "
			Thing {
				id,
				name := 'Thingy',

				new { new_name, id;
					./name = new_name
					./id = id
				}
			}

			t := Thing() # This will raise
			(t.id, t.name)"
			assert_equal [456, "Thingus"], out.values
		end

		assert_raises Ore::Missing_Argument do
			Ore.interp "
	        funk { it;
				it == true
			}
			funk() # This will raise
			"
		end

		refute_raises Ore::Undeclared_Identifier do
			Ore.interp "
			funk { it;
				it == true
			}
			funk(true), funk(false)
			"
		end

		refute_raises Ore::Undeclared_Identifier do
			Ore.interp "
			funk { it := \"true\";
				it == true
			}
			funk(true), funk()
			"
		end

		refute_raises Ore::Undeclared_Identifier do
			Ore.interp "
			funk { it := \"false\";
				it == true
			}
			funk(true), funk()
			"
		end

		refute_raises Ore::Undeclared_Identifier do
			Ore.interp "
			funk { it := true;
				it == true
			}
			funk(true), funk()
			"
		end

		refute_raises Ore::Undeclared_Identifier do
			Ore.interp "
			funk { funkit := false;
				funkit == true
			}
			funk(true), funk()
			"
		end

		refute_raises Ore::Undeclared_Identifier do
			Ore.interp "
			funk { it := nil;
				it == true
			}
			funk(true), funk()
			"
		end
	end

	def test_lexer_operator_quote_regression
		# #lex_operator was consuming quotes as symbols, creating invalid operators like ="
		# This caused { b="two" } to fail lexing when = was immediately followed by "
		out = Ore.interp '{ a=1, b="two", c: :three }.values()'
		assert_equal [1, "two", :three], out

		out = Ore.interp '{ a=1, b:"two", c: :three }.values()'
		assert_equal [1, "two", :three], out
	end

	def test_nested_type_declaration_shadowing_regression
		# When creating an instance of an inner Type (like Title) inside an outer Type's render function (like Layout), declarations in the inner Type's body (like `title,`) were incorrectly being assigned to the outer Type's instance if it had the same identifier name. This test ensures each Type/Instance has its own namespace.
		out = Ore.interp <<~CODE
		    Outer {
		    	name,

		    	new { name;
		    		./name = name
		    	}

		    	make_inner {;
		    		Inner("inner_value")
		    	}
		    }

		    Inner {
		    	name,

		    	new { name;
		    		./name = name
		    	}

		    	get_name {;
		    		name
		    	}
		    }

		    outer := Outer("outer_value")
		    inner := outer.make_inner()
		    (outer.name, inner.get_name())
		CODE
		assert_equal "outer_value", out.values[0]
		assert_equal "inner_value", out.values[1]
	end

	def test_dot_slash_inside_for_loop
		# note: Composing Array with itself allows extending or overriding behavior of Array. Notice how `values` is accessible despite being declared on the original Array type.
		without_prefix = <<~CODE
		    Array | Array {
		        each { func;
		        	for values
		        		func(it)
		        	end
		        }
		    }
		CODE

		with_prefix = <<~CODE
		    Array | Array {
		        each { func;
		        	for ./values
		        		func(it)
		        	end
		        }
		    }
		CODE

		out = Ore.interp <<~CODE
		    values := Array([1,2,3])
		    #{without_prefix}
		    values2 := []
		    values.each({it;
		    	values2.push(it)
		    })
		    values2
		CODE
		assert_equal [1, 2, 3], out.values

		out = Ore.interp <<~CODE
		    values := Array([1,2,3])
		    #{with_prefix}
		    values2 := []
		    values.each({it;
		    	values2.push(it)
		    })
		    values2
		CODE
		assert_equal [1, 2, 3], out.values
	end

	def test_broken_static_declarations
		refute_raises Ore::Missing_Ruby_Proxy_Declaration do
			Ore.interp <<~ORE
			    Thing {
			    	../abc,
			    	../def {;}
			    }

			    Thing.abc
			ORE
		end

		assert_raises Ore::Database_Not_Set_For_Table_Instance do
			Ore.interp <<~ORE
			    @load 'ore/table.ore'

			    Table.find(1)
			ORE
		end
	end

	def test_commented_closing_brace_causing_infinite_loop
		Ore.interp <<~ORE
		    Thing {
		    #}
		    }
		ORE
	end

	def test_accessing_dictionary_keys_with_dot
		# todo: I plan to make the x inside {x} to set x to whatever x happens to evaluate to. When that happens, {x}.x should return 123!
		out = Ore.interp <<~ORE
		    x := 123
		    {x}.x
		ORE
		assert_nil out
	end

	# https://github.com/figgleforth/ore-lang/issues/80
	def test_parsing_bug_from_issue_80
		assert_instance_of Ore::String_Expr, Ore.parse("'{'").first
		assert_instance_of Ore::String_Expr, Ore.parse("'('").first
		assert_instance_of Ore::String_Expr, Ore.parse("'['").first
	end

	def test_ranges_with_expression
		assert_instance_of Ore::Range, Ore.interp("x:=1, 0...x")
		assert_instance_of Ore::Range, Ore.interp("x:=1, y:=2, 0...(x + y)")
	end

	# Regression: types loaded via `variable = @load 'file.ore'` were missing enclosing_scope in interp_type
	def test_use_with_variable_can_reference_sibling_types
		out = Ore.interp <<~ORE
		    lib := @load 'test/fixtures/use_with_variable_sibling_types.ore'
		    m := lib.Main_Type()
		    m.get_sibling_value()
		ORE
		assert_equal 42, out
	end

	# Regression: sibling types should also be accessible from within functions (not just type body)
	def test_use_with_variable_can_reference_sibling_types_in_function
		out = Ore.interp <<~ORE
		    lib := @load 'test/fixtures/use_with_variable_sibling_types.ore'
		    m := lib.Main_Type()
		    m.create_sibling_in_func()
		ORE
		assert_equal 42, out
	end

	# Regression: subscript should bind after dot, so a.b[c] parses as (a.b)[c] not a.(b[c])
	def test_subscript_precedence_with_dot_access
		# Parser test: verify AST structure
		ast = Ore.parse('a.b[0]').first
		assert_instance_of Ore::Subscript_Expr, ast
		assert_instance_of Ore::Infix_Expr, ast.receiver
		assert_equal '.', ast.receiver.operator.value

		# Interpreter test: chained dot + subscript read
		out = Ore.interp <<~ORE
		    Box {
		        items := [10, 20, 30]
		    }
		    b := Box()
		    b.items[1]
		ORE
		assert_equal 20, out

		# Interpreter test: chained dot + subscript assignment
		out = Ore.interp <<~ORE
		    Box {
		        data := {x: 1, y: 2}
		    }
		    b := Box()
		    b.data[:z] = 3
		    b.data[:z]
		ORE
		assert_equal 3, out

		# Deeper chain: a.b.c[d]
		out = Ore.interp <<~ORE
		    Inner {
		        values := [100, 200]
		    }
		    Outer {
		        inner := Inner()
		    }
		    o := Outer()
		    o.inner.values[0]
		ORE
		assert_equal 100, out
	end

	# Regression: interp_func_body used to push the single, shared Func object (registered once at declaration time) as the call frame for every invocation. Two calls to the same function overlapping in time (e.g. tree recursion, where a function calls itself twice and combines the results) stomped on each other's param bindings, since they were all declaring onto the same shared scope. Each call now gets a fresh scope, so recursive calls stay isolated.
	def test_tree_recursion_does_not_share_call_frame
		out = Ore.interp <<~ORE
		    fib { n;
		        if n <= 1
		            n
		        else
		            fib(n - 1) + fib(n - 2)
		        end
		    }
		    [fib(0), fib(1), fib(2), fib(3), fib(4), fib(5), fib(10)]
		ORE
		assert_equal [0, 1, 1, 2, 3, 5, 55], out.values
	end

	# Same bug, but through an instance method, which pushes an extra type/instance scope around the (previously) shared Func frame.
	def test_tree_recursion_does_not_share_call_frame_on_instance_method
		out = Ore.interp <<~ORE
		    Counter {
		        n,

		        new { n;
					./n = n
				}

		        fib {;
		            if n <= 1
		                n
		            else
		                Counter(n - 1).fib() + Counter(n - 2).fib()
		            end
		        }
		    }
		    Counter(10).fib()
		ORE
		assert_equal 55, out
	end

	# The comment string value was being returned by the Interpreter lol.
	def test_comment_as_last_expression_bug
		out = Ore.interp "
			add { a, b;
				a + b # sum me
			}
			add(4, 8)"
		refute_kind_of Ore::String_Expr, out
	end

	# `=` used to swallow an adjacent `[` with no space between them, lexing as a single bad operator token `=[` instead of `=` followed by a delimiter.
	def test_operator_does_not_absorb_adjacent_bracket_regression
		out = Ore.lex 'a=[1,2]'
		assert_equal %i(identifier operator delimiter number delimiter number delimiter), out.map(&:type)
		assert_equal '=', out[1].value

		out = Ore.lex 'a]=b'
		assert_equal %i(identifier delimiter operator identifier), out.map(&:type)
		assert_equal '=', out[2].value
	end

	# Operators must never absorb ' " { } ( ) [ ] at all, not just at their start/end.
	def test_operator_does_not_absorb_quotes_or_braces_regression
		out = Ore.lex "5+'hello'"
		assert_equal %i(number operator string), out.map(&:type)
		assert_equal '+', out[1].value

		out = Ore.lex 'x=={y:1}'
		assert_equal '==', out[1].value

		out = Ore.lex '!(b)'
		assert_equal '!', out[0].value
	end

	def test_operator_overload_with_omitted_precedence_falls_back_to_default_regression
		out = Ore.interp '
			@operator <+> @infix { left, right;
				left + right
			}
			2 <+> 3 + 1
		'
		assert_equal 6, out

		# A real, explicit precedence must still work exactly as before.
		out = Ore.interp '
			@operator <-> @infix 500 { left, right;
				left - right
			}
			10 <-> 4
		'
		assert_equal 6, out
	end

	def test_bare_return_with_no_expression_yields_nil_regression
		out = Ore.interp '
			foo { ;
				return
			}
			foo()
		'
		assert_nil out
	end

	def test_safe_navigation_swallows_missing_member_on_every_receiver_kind_regression
		assert_nil Ore.interp 'Array().?missing'
		assert_nil Ore.interp '[].?missing'
		assert_nil Ore.interp '{}.?missing'
		assert_nil Ore.interp '(1...5).?missing'
		assert_nil Ore.interp 'Array.?uniq'

		# Real member access must still work, and plain `.` must still raise.
		assert_equal 3, Ore.interp('[1,2,3].?length()')
		assert_raises(Ore::Undeclared_Identifier) { Ore.interp '[].missing' }
		assert_raises(Ore::Cannot_Call_Instance_Member_On_Type) { Ore.interp 'Array.uniq' }
	end

	def test_range_dot_access_raises_for_undeclared_members_regression
		assert_raises(Ore::Undeclared_Identifier) { Ore.interp '(1...5).missing' }

		# `.each` must still work through the normal (non-fallback) path.
		out = Ore.interp '
			sum := 0
			for (1...3)
				sum += it
			end
			sum
		'
		assert_equal 6, out
	end

	def test_not_equal_derives_from_custom_equality_overload_regression
		src = <<~CODE
		    Point {
		    	x,
		    	y,

		    	new { x, y;
		    		./x = x
		    		./y = y
		    	}

		    	@operator == @infix 500 { left, right;
		    		left.x == right.x and left.y == right.y
		    	}
		    }

		    a := Point(1, 2)
		    b := Point(1, 2)
		    c := Point(9, 9)
		    (a != b, a != c)
		CODE
		out = Ore.interp src
		assert_equal false, out.values[0]
		assert_equal true, out.values[1]

		# Types with no `==` overload at all are unaffected -- still plain Ruby `!=` on primitives.
		refute Ore.interp '5 != 5'
		assert Ore.interp '5 != 9'
	end

	def test_calling_a_bare_shape_literal_constructs_an_instance_regression
		out = Ore.interp <<~CODE
		    @load 'ore/shape.ore'
		    s := <name: String, age: Number>('Alice', 30)
		    s.fields.0.value.value
		CODE
		assert_equal 'Alice', out

		# Also works with no matching `Shape` type loaded (bare Ore::Shape fallback).
		refute_raises do
			Ore.interp '<id: Number>(5)'
		end
	end

	def test_string_interpolation_calls_declared_to_s_regression
		out = Ore.interp <<~CODE
		    Thing {
		    	x,
		    	new { x; ./x = x }
		    	to_s {; "Thing(`x`)" }
		    }
		    t := Thing(5)
		    "value: `t`"
		CODE
		assert_equal 'value: Thing(5)', out

		# A type with no to_s still falls back to the raw dump -- no change there.
		out = Ore.interp <<~CODE
		    Bare { x, new { x; ./x = x } }
		    b := Bare(5)
		    "value: `b`"
		CODE
		assert_includes out, 'Ore::Instance'

		# Primitives unaffected.
		assert_equal 'n: 8', Ore.interp('x := 5+3
			"n: `x`"')
	end

	def test_stringify_for_display_finds_to_s_on_shorthand_constructed_literals_regression
		interpreter = Ore::Interpreter.new
		result      = interpreter.run '[1, 2, 3]'
		assert_equal '[1, 2, 3]', interpreter.stringify_for_display(result)

		# @puts and bin/ore's `-p` both go through this same path.
		assert_equal '[1, 2, 3]', Ore.interp('[1,2,3].to_s()')
	end

	def test_nested_array_to_s_regression
		interpreter = Ore::Interpreter.new
		result      = interpreter.run '[].push([1,2,3])'
		assert_equal '[[1, 2, 3]]', interpreter.stringify_for_display(result)

		# String had no to_s{;} at all until this fix -- an array of strings would have raised
		# Undeclared_Identifier trying to call .to_s() on each element.
		assert_equal '[a, b, c]', Ore.interp("['a','b','c'].to_s()")
	end

	def test_array_of_symbols_to_s_regression
		out = Ore.interp <<~CODE
		    d := {x: 1, y: 2}
		    d.keys().to_s()
		CODE
		assert_equal '[x, y]', out
	end

	def test_dictionary_and_tuple_literals_find_declared_to_s_regression
		assert_equal '{x: 1, y: 2}', Ore.interp('{x: 1, y: 2}.to_s()')
		assert_equal '(1, 2, 3)', Ore.interp('(1, 2, 3).to_s()')
	end

	def test_tuple_values_are_not_the_stale_type_name_regression
		out = Ore.interp <<~CODE
		    t := (1, 2, 3)
		    t.values
		CODE
		assert_equal [1, 2, 3], out
	end

	def test_nil_and_bool_find_declared_to_s_and_truthiness_regression
		assert_equal 'nil', Ore.interp('nil.to_s()')
		assert_equal 'true', Ore.interp('true.to_s()')
		assert_equal 'false', Ore.interp('false.to_s()')
	end

	def test_composition_chain_without_a_body_does_not_hang_the_parser_regression
		refute_raises { Ore.parse 'A & B' }
		refute_raises { Ore.parse 'A | B | C' }
	end

	def test_anonymous_composition_regression
		src = <<~CODE
		    A { x := 1, shared {; 'from A' } }
		    B { y := 2, shared {; 'from B' } }

		    union        := (A | B)()
		    intersection := (A & B)()
		    difference   := (A ~ B)()
		    symmetric    := (A ^ B)()

		    (union.x, union.y, union.shared(), intersection.shared(), difference.x, symmetric.x, symmetric.y)
		CODE
		out = Ore.interp src
		assert_equal [1, 2, 'from A', 'from A', 1, 1, 2], out.values

		# Intersection/difference correctly DON'T keep what they're supposed to drop.
		assert_raises(Ore::Undeclared_Identifier) { Ore.interp "#{src}\nintersection.x" }
		assert_raises(Ore::Undeclared_Identifier) { Ore.interp "#{src}\ndifference.shared()" }

		# Comparable with the existing Type comparison operators, same as any named composed type.
		out = Ore.interp <<~CODE
		    Flying { can_fly := true }
		    Swimming { can_swim := true }
		    Duck | Flying | Swimming { name := 'duck' }

		    (Duck =>= (Flying | Swimming), (Flying | Swimming) =>= Duck)
		CODE
		assert_equal [true, false], out.values
	end

	def test_bare_scope_operator_does_not_corrupt_parsing_regression
		%w(./ ../ ~/).each do |op|
			# Not the last thing in the program -- this used to crash.
			out = Ore.interp "x := #{op}\ny := 1\nx"
			assert_nil out

			# Bare, unassigned, not the last statement -- this used to silently vanish (harmless in
			# itself, but confirms the newline it used to eat is no longer swallowed).
			out = Ore.interp "#{op}\n5"
			assert_equal 5, out

			# Still fine as the literal last token in the file (the case that always worked).
			assert_nil Ore.interp(op)
		end
	end

	def test_labeled_call_arguments_regression
		src = <<~CODE
		    send_greeting { to person; person }
		CODE

		# A labeled call matches the declared label at that position.
		assert_equal 42, Ore.interp("#{src}\nsend_greeting(to: 42)")

		# Labels are opt-in at the call site -- a bare positional call still works even though the
		# param declares a label.
		assert_equal 42, Ore.interp("#{src}\nsend_greeting(42)")

		# A label that doesn't match the declared one raises, whether the param has a different label...
		assert_raises(Ore::Argument_Label_Mismatch) do
			Ore.interp("#{src}\nsend_greeting(wrong: 42)")
		end

		# ...or no label at all.
		assert_raises(Ore::Argument_Label_Mismatch) do
			Ore.interp('add { a, b; a + b }
				add(a: 1, 2)')
		end

		# Labels work through constructors too (`new{;}` params).
		out = Ore.interp <<~CODE
		    Point {
		    	x,
		    	y,
		    	new { at x, at y;
		    		./x = x
		    		./y = y
		    	}
		    }
		    p := Point(at: 3, at: 4)
		    (p.x, p.y)
		CODE
		assert_equal [3, 4], out.values

		# Labels compose with defaults normally -- omitting a labeled, defaulted arg still falls back.
		out = Ore.interp <<~CODE
		    greet { with name := "World"; "Hello, `name`" }
		    (greet(), greet(with: "Ore"))
		CODE
		assert_equal ['Hello, World', 'Hello, Ore'], out.values
	end

	def test_circumfix_elements_do_not_swallow_nil_init_regression
		# The actual bug: an undeclared non-last element used to silently become nil.
		assert_raises(Ore::Undeclared_Identifier) do
			Ore.interp 'foo { a, b; a + b }
				foo(undeclared_var, 5)'
		end
		assert_raises(Ore::Undeclared_Identifier) do
			Ore.interp 'x := 1
				[undeclared_var, x]'
		end
		assert_raises(Ore::Undeclared_Identifier) do
			Ore.interp 'x := 1
				(undeclared_var, x)'
		end

		# Already-declared identifiers still pass through as plain references, not fresh
		# shadow-declarations, for calls, arrays, and tuples alike.
		out = Ore.interp 'foo { a, b; a + b }
			x := 5
			y := 8
			foo(x, y)'
		assert_equal 13, out

		out = Ore.interp 'x := 1
			y := 2
			[x, y]'
		assert_equal [1, 2], out.values

		out = Ore.interp 'x := 1
			y := 2
			(x, y)'
		assert_equal [1, 2], out.values
	end

	def test_postfix_unless_and_until_regression
		assert_nil Ore.interp('5 unless true')
		assert_equal 5, Ore.interp('5 unless false')

		out = Ore.interp('x := 0
			x += 1 until x >= 3
			x')
		assert_equal 3, out
	end

	def test_string_literal_matching_a_prefix_symbol_regression
		assert_equal true, Ore.interp('"hi!".end_with?("!")')
		assert_equal 1, Ore.interp("'!'.length")
		assert_equal 1, Ore.interp("'-'.length")
		assert_equal 6, Ore.interp("'return'.length")

		# Real prefix operators are unaffected.
		assert_equal false, Ore.interp('!true')
		assert_equal(-5, Ore.interp('-5'))
	end

	def test_comparing_two_type_objects_does_not_dispatch_instance_operator_overload_regression
		out = Ore.interp <<~CODE
		    @load 'ore/shape.ore'
		    a := Field('id', nil, String)
		    b := Field('id', nil, String)
		    a == b
		CODE
		assert_equal true, out

		out = Ore.interp <<~CODE
		    @load 'ore/shape.ore'
		    sa := <name: String, age: Number>('Alice', 30)
		    sb := <name: String, age: Number>('Alice', 30)
		    sc := <name: String, age: Number>('Alice', 99)
		    (sa == sb, sa == sc)
		CODE
		assert_equal [true, false], out.values
	end
end
