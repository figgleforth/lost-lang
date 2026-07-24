## Now

- Begin porting to Odin!

## Next — persistence phase (deferred until I feel like it)

- Table associations (`belongs_to`/`has_many`) — needed the moment `Player` needs a `Team`.
- jsonb-like column support — needed for `Mod#effects`, `Skill`'s per-attribute columns.
- Related to issue #75 (ORM improvements) but that issue is specifically about migrations —
  associations/jsonb are a separate, currently unfiled, gap.

## Later — web server phase

- Wire the resolution logic behind `ore/server.ore` routes once persistence lands.

---
## Unfinished features (intentional, not bugs)

- Stride overlap for `for x by n,overlap` — `getting_started.md` documents
  `for x reject by 2,1` / `for x each by 3,1` style overlapping chunks, but the parser doesn't
  support the second stride argument yet (`src/compiler/parser.rb:155`: "Currently `stride`
  doesn't support option to overlap elements"). This was meant to be implemented, not just
  aspirational docs — needs the parser to accept `by <stride>,<overlap>` and the interpreter's
  chunking (`each_slice` today) to respect the overlap instead of using non-overlapping slices.

## Known bugs — not yet filed as GitHub issues

- Tuple-in-tuple has infinite members — `((), true).0.1`, `.0.2`, `.0.3`... all return a
  Tuple instead of erroring past the actual length.
- `Array#map` crashes if the anonymous function doesn't explicitly declare `it`/`at` as params
  (`arr.map({; it * 2 })` fails; `arr.map({it, at; it * 2})` works) — documented inline in
  `ore/array.ore`.
- No try/catch — unhandled runtime errors crash the program outright. Ore errors are Ruby
  exceptions under the hood already, so the interpreter just needs to catch and hand off to a
  user-defined handler. Matters most for web routes, file I/O, DB calls.
- Nil-safe access — `x.?method` should return nil instead of raising when `x` is nil.
- Interpolation pipes in multiline text aren't escaped properly (`src/compiler/lexer.rb:171`,
  repro in `examples/basic_page.ore`) — causes the interpreter to mis-interpolate.
- Dict keys that shadow a built-in dict method name (`keys`, `values`, etc.) break lookup —
  should check the dict's own scope before falling back to the built-in
  (`src/runtime/interpreter.rb`, ~L927).
- `String#split` requires an explicit `nil` default arg or it fails (`ore/string.ore:16`).
- `type_checker_test.rb:156` — a test that should currently be failing and isn't; smells like a
  latent type-checker bug, worth an isolated repro before trusting the type checker further.

## Code-quality backlog — folded in from a repo-wide inline `todo`/`bug`/`note` sweep (was
`review.md`, retired now that this is the single backlog file)

Grouped by theme; file:line references are current as of the sweep and will drift as the code
moves, use them as a starting grep, not gospel.

**Error handling / error output** (mostly overlaps #74):
- Seven separate `# todo: Proper error` placeholders scattered through
  `src/runtime/interpreter.rb` — real error types needed instead of generic ones.
- `src/runtime/error_formatter.rb:44,48` — doesn't display source code properly, unclear how to
  get the source string at that point.
- `src/runtime/errors.rb:97` — a case that's silently not printing anything to stdout.
- `src/runtime/interpreter.rb:966` — a `rescue` is catching `ArgumentError` broadly instead of
  the specific `Undeclared_Identifier` it's meant for; root cause of the `ArgumentError: empty
  string` case was never tracked down.

**Parser robustness:**
- `src/compiler/parser.rb:340` — unhandled edge case when a comment's value is literally `"}"`.
- `src/compiler/parser.rb:599` — a comma is discarded instead of implying a tuple in
  `#complete_expression` (possibly related to #78, tuple unpacking).
- `src/compiler/lexer.rb:208` — operators are still allowed to start/end with `` ' " { } ( ) ``
  and should be disallowed.

**Language design loose ends:**
- `src/shared/constants.rb:3` — `UNPACK_OPERATOR = '@'` collides conceptually with
  `Ore::BUILTIN_OPERATOR` (also `@`); pick a distinct symbol for one of them.
- `src/runtime/interpreter.rb:984,992` — array `<<` is special-cased in the interpreter instead
  of being a real operator declaration on `Array`; revisit once operator declarations exist.
- `src/runtime/interpreter.rb:1819` — sibling scopes are assumed read-only; assumption was
  never actually double-checked.
- `src/runtime/interpreter.rb:1838` — builtins aren't user-extensible yet; a rough shape of the
  requirements exists in the comment but nothing's implemented.
- `ore/preload.ore:13` — `Iterable` composition exists but is unused; consider making it behave
  like a Swift-style protocol.

**ORM / stdlib gaps:**
- `src/external/ruby/table.rb:35` — query results should convert to a `Record` instance instead
  of raw data.
- `src/external/ruby/table.rb:52` — `#insert` should maybe return `self` or a hash of the
  inserted row instead of just the id.
- `ore/database.ore:3` — `connection` field is typed as raw `Sequel::SQLite::Database`, needs a
  real Ore type.
- `ore/date_time.ore:1` — no `Date_Time` class in `scopes.rb` yet.

**Test-documented gaps:**
- `test/type_checker_test.rb:35` — no error raised for an identifier with an unknown type on
  the RHS; maybe should warn.
- `test/regression_test.rb:395` — plan to make bare `{x}` implicitly set `x`, so `{x}.x` returns
  `123`.
- `test/parser_test.rb:400,415` — design question of whether `return` should be a prefix
  keyword instead of producing a `when_true`, and whether `when_true`/`when_false` naming should
  better convey that they return arrays.

## Filed GitHub issues (open)

- #79 Type checking phase between Parser and Interpreter
- #78 Unpack tuples (`x, y, z = some_tuple`)
- #75 ORM improvements (migrations/schema — see "Next" above for the related-but-different
  associations/jsonb gap)
- #74 Improve error output (missing code locations on some errors, e.g.
  `Invalid_Subscript_Left_Operand`)
- #70 Variable function arguments (varargs, `funk { ...; }`)
- #66 Missing primitive operations (`type_of`, `to_s`, `chr` as intrinsics)
- #65 [bug] Type composition broken when using infix operator for Type
  (`Html.Whatever {}` → `Undeclared_Identifier`)
- #57 Type annotations — readme documents gradual typing (`x: String`, `x := 4`) as already
  shipped; **verify this issue is actually stale and close it** rather than treat as open work.
- #54 Stack navigation directive (`#cd some_scope`, `#cd..`)
- #51 Percent literals (`%str(...)`, `%sym(...)`)
- #49 Custom operators — readme documents `@operator` as already shipped; **verify stale and
  close** like #57.
