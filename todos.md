- [ ] Replace all `# todo: Proper error` placeholders scattered through `src/runtime/interpreter.rb` — real error types needed instead of generic ones.
- [ ] Nil-safe access — `x.?method` should return nil instead of raising when `x` is nil.
- [ ] `src/runtime/interpreter.rb` — array `<<` is special-cased in the interpreter instead of being a real operator declaration on `Array`; revisit once operator declarations exist.
- [ ] Stride overlap for `for x by n,overlap` — `getting_started.md` documents `for x reject by 2,1` / `for x each by 3,1` style overlapping chunks, but the parser doesn't support the second stride argument yet (`src/compiler/parser.rb`: "Currently `stride` doesn't support option to overlap elements"). This was meant to be implemented, not just aspirational docs — needs the parser to accept `by <stride>,<overlap>` and the interpreter's chunking (`each_slice` today) to respect the overlap instead of using non-overlapping slices.


**Bugs:**
- [ ] Tuple-in-tuple has infinite members — `((), true).0.1`, `.0.2`, `.0.3`... all return a Tuple instead of erroring past the actual length.
- [ ] No try/catch — unhandled runtime errors crash the program outright. Ore errors are Ruby exceptions under the hood already, so the interpreter just needs to catch and hand off to a user-defined handler. Matters most for web routes, file I/O, DB calls.
- [ ] Update? Dict keys that shadow a built-in dict method name (`keys`, `values`, etc.) break lookup — should check the dict's own scope before falling back to the built-in (`src/runtime/interpreter.rb`, ~L927).
- [ ] Update? `src/runtime/error_formatter.rb` — doesn't display source code properly, unclear how to get the source string at that point.

**Miscellaneous:**
- [ ] Work on Odin port scaffolding on the side, but no rush because I want to keep improving the Ruby version.
- [ ] Table associations (`belongs_to`/`has_many`) — needed the moment `Player` needs a `Team`.
- [ ] jsonb-like column support.
- [ ] Related to issue #75 (ORM improvements) but that issue is specifically about migrations — associations/jsonb are a separate, currently unfiled, gap.

**Parser robustness:**
- [ ] `src/compiler/parser.rb` — a comma is discarded instead of implying a tuple in `#complete_expression` (possibly related to #78, tuple unpacking).
- [ ] `src/compiler/lexer.rb` — operators are still allowed to start/end with `` ' " { } ( ) `` and should be disallowed.

**Language design loose ends:**
- [ ] `src/shared/constants.rb` — `UNPACK_OPERATOR = '@'` collides conceptually with `Ore::BUILTIN_OPERATOR` (also `@`); pick a distinct symbol for one of them.
- [ ] `src/runtime/interpreter.rb` — sibling scopes are assumed read-only; assumption was never actually double-checked.
- [ ] `src/runtime/interpreter.rb` — builtins aren't user-extensible yet; a rough shape of the requirements exists in the comment but nothing's implemented.
- [ ] `ore/preload.ore` — `Iterable` composition exists but is unused; consider making it behave like a Swift-style protocol.

**ORM / stdlib gaps:**
- [ ] `src/external/ruby/table.rb` — query results should convert to a `Record` instance instead of raw data.
- [ ] `src/external/ruby/table.rb` — `#insert` should maybe return `self` or a hash of the inserted row instead of just the id.
- [ ] `ore/database.ore` — `connection` field is typed as raw `Sequel::SQLite::Database`, needs a real Ore type.
- [ ] `ore/date_time.ore` — no `Date_Time` class in `scopes.rb` yet.

**Test-documented gaps:**
- [ ] `test/type_checker_test.rb` — no error raised for an identifier with an unknown type on the RHS; maybe should warn.
- [ ] `test/regression_test.rb` — plan to make bare `{x}` implicitly set `x` if it's declared in the scope, so `{x}.x` returns `123`.
- [ ] `test/parser_test.rb` — design question of whether `return` should be a prefix keyword instead of producing a `when_true`, and whether `when_true`/`when_false` naming should better convey that they return arrays.

**Done:**
- [x] A trailing `#` comment on the last line of a function or program body silently becomes the return value instead of being discarded. Repro: `add { a, b; a + b  # sum them }` then `add(4, 8)` returns the comment `"sum them"` instead of `12`
- [x] Add extra period in the middle of range operators .. -> ...
- [x] `Array#map` crashes if the anonymous function doesn't explicitly declare `it`/`at` as params (`arr.map({; it * 2 })` fails; `arr.map({it, at; it * 2})` works) — documented inline in `ore/array.ore`.
