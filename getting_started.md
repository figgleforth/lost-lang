### Quick Start

> Requires Ruby `3.4.1` or higher, and Bundler

```bash
git clone https://github.com/figgleforth/ore-lang.git
cd ore-lang
bundle install
bundle exec bin/ore ore/examples/hello.ore # => Hello, Ore!
```

### Table of Contents
 
- [Project Structure](#project-structure)

### Project Structure

- [`src/readme`](src/readme.md) details the architecture and contains instructions for running your own programs
- [`learn`](learn) contains more useful code examples
- [`examples`](ore/examples) contains code examples written in Ore
- [`ore`](ore) contains code for the Ore standard library
- [`src`](src) contains code implementing Ore
    - [Lexer](src/compiler/lexer.rb) – Source code to Lexemes
    - [Parser](src/compiler/parser.rb) – Lexemes to Expressions
    - [Type_Checker](src/compiler/type_checker.rb) – Basic type annotation checking
    - [Interpreter](src/runtime/interpreter.rb) – Entry point; `run(source)` lexes, parses, and executes
