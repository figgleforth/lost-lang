package lexer

import "core:fmt"
import "core:unicode/utf8"

Lexeme :: struct {
    start, end: int,
    value: string,
}

Source_File :: struct {
    path: string,
    bytes: []byte
}

Lexer :: struct {
    x, y, i: int, // col, line, index into source
    lexemes: [dynamic]^Lexeme,
    source_file: Source_File,
}

curr :: proc(l: ^Lexer) -> string {
    r, width := utf8.decode_rune(l.source_file.bytes[l.i:])
    return string(l.source_file.bytes[l.i:(l.i + width)])
}

eat :: proc(l: ^Lexer, expected: string) -> (text: string, matches: bool) {
    start := l.i
    l.i += len(expected)
    text = string(l.source_file.bytes[start:l.i])
    matches = text == expected
    return
}

to_lexeme :: proc(l: ^Lexer, text: string, start_index: int) -> Lexeme {
    lexeme := Lexeme {
        start = start_index,
        end = start_index + len(text),
        value = text
    }

    append(&l.lexemes, &lexeme)
    return lexeme
}
