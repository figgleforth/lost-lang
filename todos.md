**Miscellaneous:**
- [ ] Table associations (`belongs_to`/`has_many`): needed the moment `Player` needs a `Team`.
- [ ] jsonb-like column support.
- [ ] Related to issue #75 (ORM improvements) but that issue is specifically about migrations: associations/jsonb are a separate, currently unfiled, gap.
- [ ] No JSON encode/decode exposed to Ore: `require 'json'` only used internally for parsing POST bodies (`interpreter.rb`).
- [ ] No outbound HTTP client: Ore can serve requests but can't make them.
- [ ] No `ENV`/config access: only I/O primitive is `File_System`.
- [ ] No in-Ore testing/assert facility: Minitest only tests the interpreter itself.
- [ ] Implement way to extract mulitple values from tuples like `x, y := (1, 2)`
- [ ] Percent literals `%str(boo hoo COOL)` for ['boo', 'hoo', 'COOL'] `%sym(BOO hoo cool)` for [:BOO,  :hoo,  :cool], etc.
- [ ] Replace all `# todo: Proper error` placeholders scattered through `src/runtime/interpreter.rb`: real error types needed instead of generic ones.
- [ ] Stride overlap for `for x by n,overlap`: `getting_started.md` documents `for x reject by 2,1` / `for x each by 3,1` style overlapping chunks, but the parser doesn't support the second stride argument yet (`src/compiler/parser.rb`: "Currently `stride` doesn't support option to overlap elements"). This was meant to be implemented, not just aspirational docs: needs the parser to accept `by <stride>,<overlap>` and the interpreter's chunking (`each_slice` today) to respect the overlap instead of using non-overlapping slices.
- [ ] An operator for checking AST types. For example, `func{;} ==== Func_Expr`. I'm only using four equals to illustrate.
- [ ] `help {expr;}` or `@help` that accepts any expression and returns information about the Type, primitive, function, etc. Literally any expression should be able to be described given its AST. You even have access to the live values so the information can be dynamic to reflect what the user is actually asking about.
- [ ] Switch statement / pattern matching: required for @help / help{expr;} function.
- [ ] Work on Odin port scaffolding on the side, but no rush because I want to keep improving the Ruby version.

**Bugs:**
- [ ] Tuple-in-tuple has infinite members: `((), true).0.1`, `.0.2`, `.0.3`... all return a Tuple instead of erroring past the actual length.
- [ ] No try/catch: unhandled runtime errors crash the program outright. Ore errors are Ruby exceptions under the hood already, so the interpreter just needs to catch and hand off to a user-defined handler. Matters most for web routes, file I/O, DB calls.
- [ ] Update? Dict keys that shadow a built-in dict method name (`keys`, `values`, etc.) break lookup: should check the dict's own scope before falling back to the built-in (`src/runtime/interpreter.rb`, ~L927).
- [ ] Update? `src/runtime/error_formatter.rb`: doesn't display source code properly, unclear how to get the source string at that point.
- [ ] `=~`/`!~` (regex match) are listed in `COMPARISON_OPERATORS` (`src/shared/constants.rb`) but missing from `INFIX`, so the parser never builds an `Infix_Expr` for them: same bug class the `!==` fix addressed. `'abc' =~ 'xyz'` silently parses as disconnected expressions instead of erroring. Needs `=~`/`!~` added to `INFIX`, and an actual regex-match implementation (currently nothing in `interp_infix`'s `COMPARISON_OPERATORS` branch handles them beyond the `left.send` fallback).
- [ ] `<=>` works for Numbers/Strings only by accident: it falls through to `left.send('<=>', right)` in `interp_infix`, which works because number/string literals decay to plain Ruby values with a native `<=>`. Custom Instances have no `<=>` defined, so `<=>` on user-defined types raises rather than erroring cleanly or doing something sensible.

**Parser robustness:**
- [ ] `src/compiler/parser.rb`: a comma is discarded instead of implying a tuple in `#complete_expression` (possibly related to tuple unpacking).
- [ ] Update? `src/compiler/lexer.rb`: operators are still allowed to start/end with `` ' " { } ( ) `` and should be disallowed.
- [ ] Change set comparison operators to `=== =!= =/= =>= =<=` from `=== !== =/= >== ==<` to be more consistent

**Language design loose ends:**
- [ ] Rename @use to @load? Or something else because "use" doesn't clearly explain the behavior.
- [ ] What should the default value for uninitilized declarations be? `x: Number` should probably start as 0 instead of nil. The value should depend on the type as well, like a String should be "" by default. Etc.
- [ ] `@valid` directive: validate whether a call would type-check without actually invoking it, e.g. `@valid identity(123)` #=> true, `@valid identity("1")` #=> false. Return-type syntax now exists, so this is unblocked: just needs the directive itself: check arg count/types against a real function's `param_types`/`return_type` (both now on `Ore::Func`) without invoking it.
- [ ] Related idea, tabled for now: an operator to structurally match a function's param signature against a shape, e.g. `add ==== {Number, Number;}`.
- [ ] Type contracts (`: Type` annotations, both nominal and signature) are only ever checked on *reassignment* (`interp_infix_assignment`): never on the first, self-declaring assignment. `to_string: Num_to_str = { totally wrong shape }` isn't caught. Pre-existing architectural gap, not new: applies equally to plain nominal types.
- [ ] `test/regression_test.rb`: plan to make bare `{x}` implicitly set `x` if it's declared in the scope, so `x=123, {x}` should set x to 123.
- [ ] `src/shared/constants.rb`: `UNPACK_OPERATOR = '@'` collides conceptually with `Ore::BUILTIN_OPERATOR` (also `@`); pick a distinct symbol for one of them.
- [ ] `src/runtime/interpreter.rb`: sibling scopes are assumed read-only; assumption was never actually double-checked.
- [ ] `src/runtime/interpreter.rb`: builtins aren't user-extensible yet; a rough shape of the requirements exists in some comment but nothing's implemented.
- [ ] `ore/preload.ore`: `Iterable` composition exists but is unused; consider making it behave like a Swift-style protocol.

**ORM / stdlib gaps:**
- [ ] `src/external/ruby/table.rb`: query results should convert to a `Record` instance instead of raw data.
- [ ] `src/external/ruby/table.rb`: `#insert` should maybe return `self` or a hash of the inserted row instead of just the id.
- [ ] `ore/database.ore`: `connection` field is typed as raw `Sequel::SQLite::Database`, needs a real Ore type.
- [ ] `ore/date_time.ore`: no `Date_Time` class in `scopes.rb` yet.

**Test-documented gaps:**
- [ ] `test/type_checker_test.rb`: no error raised for an identifier with an unknown type on the RHS; maybe should warn.
- [ ] `test/parser_test.rb`: design question of whether `return` should be a prefix keyword instead of producing a `when_true`, and whether `when_true`/`when_false` naming should better convey that they return arrays.

**Done:**
- [x] A trailing `#` comment on the last line of a function or program body silently becomes the return value instead of being discarded. Repro: `add { a, b; a + b  # sum them }` then `add(4, 8)` returns the comment `"sum them"` instead of `12`
- [x] Add extra period in the middle of range operators .. -> ...
- [x] `Array#map` crashes if the anonymous function doesn't explicitly declare `it`/`at` as params (`arr.map({; it * 2 })` fails; `arr.map({it, at; it * 2})` works): documented inline in `ore/array.ore`.
- [x] Nil-safe access: `x.?method` should return nil instead of raising when `x` is nil.
- [x] Validate whether the precedence is even used when declaring an operator. Yes, it is.
- [x] `src/runtime/interpreter.rb`: array `<<` is special-cased in the interpreter instead of being a real operator declaration on `Array`; revisit once operator declarations exist.
- [x] Add Type set comparison operators
- [x] Function signature literals (`Type{Param;}` as a value/alias, `name: Type{Param;}` self-declaring): `Ore::Func_Signature`, with `Invalid_Func_Signature` raised for malformed ones.
- [x] Return-type annotations on real functions: `name: Type {}` prefix and `{params -> Type; ...}` inline (works for anonymous functions too): plus runtime enforcement (`Type_Contract_Violation` if the actual return value doesn't match).
- [x] Structural signature matching: reassigning a signature-aliased identifier now checks a real function's actual param/return types against the alias, not just nominal string equality.
