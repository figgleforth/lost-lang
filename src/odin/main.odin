package ore

import os "core:os"
import fmt "core:fmt"
import mem "core:mem"
import l "lexer"

// to avoid prefixing with l. below
Lexer :: l.Lexer
Source_File :: l.Source_File

puts :: fmt.println
path :: "../../examples/hello.ore"

source_files: map[string]Source_File
source_arena: mem.Arena
source_arena_memory: []byte

main :: proc() {
    source_arena_memory = make([]byte, 16 * mem.Megabyte)
    mem.arena_init(&source_arena, source_arena_memory)
    defer mem.arena_free_all(&source_arena)
    source_allocator := mem.arena_allocator(&source_arena)

    source_files = make(map[string]Source_File, allocator = source_allocator)
    bytes, err := os.read_entire_file_from_path(path, allocator = source_allocator)

    if err != os.ERROR_NONE {
        puts("error opening", path, "->", err)
        return
    }

    sf := Source_File {
        path = path, bytes = bytes
    }

    lexer := Lexer {
        x = 1, y = 1, // i = 0 by default already
        source_file = sf
    }

    source_files[path] = sf

//    for at in lexer.i ..< len(lexer.source_file.bytes) {
//        it := lexer.source_file.bytes[at]
//    }

}
