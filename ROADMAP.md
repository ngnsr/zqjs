# Roadmap

Each milestone ships unit tests, golden/edge-case tests, a runnable demo and doc updates.
"Required regression tests" are acceptance criteria: the milestone isn't done without them.

| # | Milestone | Status |
|---|---|---|
| 1 | Lexer, Pratt parser for expressions, AST, diagnostics, `--dump-ast` | **done** |
| 2 | `let`/`const`, assignment, blocks, `if`/`while`/`for`, resolver | – |
| 3 | Tree-walking interpreter, `runtime/ops.zig`, UTF-16 strings, `print`, diff harness | – |
| 4 | Bytecode compiler, constant pool, `max_stack`, disassembler | – |
| 5 | Stack VM with `step()` / `--trace`, instruction budget | – |
| 6 | Functions, cells/closures, growable stack, call-depth limit | – |
| 7 | Objects, arrays, atoms, ordered properties, prototypes | – |
| 8 | Mark-and-sweep GC, temp roots, stress modes, heap limit | – |
| 9 | Embedding API (handles, `NativeCtx`), then C ABI | – |
| 10 | Fuzzing all layers, benchmarks, Guard Malloc / Valgrind CI | – |
| 11 | Bytecode inspector/debugger: single-step, stack/frames, heap browser, manual GC, breakpoints | – |

## Required regression tests by milestone

**M1 (done)**
- UTF-16 decoding of literals: lone surrogate `'\uD800'` (1 unit), `'\u{1F600}'` = `'😀'` =
  raw `'😀'` (2 units), `\u{10FFFF}` ok, `\u{110000}` SyntaxError, `\u{}` SyntaxError
- error paths: every allocation of a parse failing once (`checkAllAllocationFailures`), no leaks
- limits: source size, nesting via parentheses, nesting via a long `+` chain
- every `ok` / `syntax` case cross-checked against node (`zig build check-node`)
- fuzz target: lexer + parser on arbitrary bytes

**M3:** surrogates at runtime: `length`, `charCodeAt`, concatenating two lone halves gives one
pair, printing a lone surrogate gives U+FFFD (as node).
**M6:** stack relocation: deep recursion forcing several moves, native→JS callback growing
the stack then reading its args, closure created before a move and called after it. Whole suite
under `-Dstack-stress`.
**M7:** property order: `0,1,b,a` example, `"4294967295"` vs `"4294967294"`, `"01"`, `"-1"`,
delete + re-add.
**M8:** GC rooting and atom lifetime: the targeted stress tests in DESIGN_DECISIONS D10 and
D11. Whole suite under `-Dgc-stress`. OOM injection over script runs.
