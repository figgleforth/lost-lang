### What's here?

This [`src`](.) folder contains the implementation of Lost in Ruby. Source code moves through five phases: **Lexer → Parser → Type Checker → Declarator → Interpreter.** `Interpreter` (`src/runtime/interpreter.rb`) is the entry point: it owns a `Lexer` and `Parser`, drives all five phases via `run(source)`, and holds all execution state.

Rather than listing individual files here (they move around; check the directory itself for the current contents), here's what each one is for:

- **`compiler/`**: turns Lost source into a type-checked AST (tokenizing, parsing, static type checking, and the forward-declaration pass that lets code reference a function or type before its own definition).
- **`runtime/`**: executes that AST (the interpreter itself, the scope hierarchy: Global, Type, Instance, Func, Route, etc., and runtime error definitions).
- **`external/ruby/`**: Ruby-backed implementations of Lost's built-in types (`String`, `Array`, `Number`, etc.) that Lost-level proxy methods delegate into.
- **`systems/`**: larger subsystems layered on top of the interpreter, e.g. HTML rendering.
- **`shared/`**: constants and helper functions used across every phase.
- **`lost.rb`**: the entry point. Requires everything and exposes the `Lost` module's convenience methods (`Lost.lex`, `Lost.parse`, `Lost.interp`, and their `_file` counterparts).

---

### Running Your Own Programs With Ruby

Call `run` with source code and it handles lexing, parsing, and execution:

```ruby
require './src/lost'

interpreter = Lost::Interpreter.new
result      = interpreter.run "'Hello, World!'" # => Hello, World!
```

You can also step through each phase manually:

```ruby
require './src/lost'

lexer       = Lost::Lexer.new "'Hello, World!'"
lexemes     = lexer.output       # => array of Lexemes

parser      = Lost::Parser.new lexemes
expressions = parser.output      # => array of Expressions

interpreter       = Lost::Interpreter.new
interpreter.input = expressions
result            = interpreter.output # => Hello, World!
```

Or use the `Lost` module convenience methods:

```ruby
require './src/lost'

source      = '"Hello, Again!"'
lexemes     = Lost.lex source        # => array of Lexemes
expressions = Lost.parse source      # => array of Expressions
result      = Lost.interp source     # => Hello, Again!

source_file = './my_program.tape'
lexemes     = Lost.lex_file source_file
expressions = Lost.parse_file source_file
result      = Lost.interp_file source_file
```

### Running Your Own Programs By Command Line

This is the quickest way to run code:

```bash
bundle exec bin/lost file.tape
```

You can also use `bin/lost interp` for direct source as string evaluation:

```bash
bundle exec bin/lost interp "4 + 8"
```

For the full list of subcommands (parsing/lexing/declaration inspection, the REPL, etc.), run:

```bash
bundle exec bin/lost --help
```
