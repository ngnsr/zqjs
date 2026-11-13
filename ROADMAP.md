# Roadmap

Each milestone ships unit tests, golden/edge-case tests, a runnable demo and doc updates.
"Required regression tests" are acceptance criteria: the milestone isn't done without them.

| # | Milestone | Status |
|---|---|---|
| 1 | Lexer, Pratt parser for expressions, AST, diagnostics, `--dump-ast` | **done** |
| 2 | `let`/`const`, assignment, blocks, `if`/`while`/`for`, `break`/`continue`, resolver | **done** |
| 3 | Tree-walking interpreter, `runtime/ops.zig`, UTF-16 strings, `print`, diff harness | **done** |
| P1 | Accurate exponentiation: JS special cases, musl/Arm `pow`, accuracy and portability checks (D25) | **done** |
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
- UTF-16 decoding of literals: lone surrogate `'\uD800'` (1 unit), `'\u{1F600}'` = `'\uD83D\uDE00'` =
  raw `'😀'` (2 units), `\u{10FFFF}` ok, `\u{110000}` SyntaxError, `\u{}` SyntaxError
- error paths: every allocation of a parse failing once (`checkAllAllocationFailures`), no leaks
- limits: source size, nesting via parentheses, nesting via a long `+` chain
- every `ok` / `syntax` case cross-checked against node (`zig build check-goldens`)
- fuzz target: lexer + parser on arbitrary bytes

**M2 (done)**
- resolver: shadowing vs same-scope redeclaration (let/let, let/const, one statement, `for` head),
  hoisting (`{ x; let x }`, `let x = x`), sibling-block slot reuse, `for` head scope vs body scope
- `undefined`/`NaN`/`Infinity`: SyntaxError at script level only
- global reads resolve; global writes (`=`, `+=`, `++`) are `Unsupported(global_assignment)`
- `const` writes resolve (no early error)
- `break`/`continue`: outside a loop, `break foo` (labels, also outside loops), `break\nfoo` (ASI)
- contextual `let`: `let;`, `let = 1`, `let in x`, `let\nx = 1`, `if (c) let x = 1`
- assignment targets, `++`/`--` targets, `++x ** 2` vs `-x ** 2`
- error paths and fuzzing over parse + resolve + dump; the node check now *runs* scripts

**M3 (done)**: every item below is a program in `tests/diff` whose output equals node's.
TDZ and const, from LANGUAGE.md §5: `x; let x`, `let x = x`, inner-block hoisting;
`x = print('rhs'); let x` prints then throws, `x += print('rhs'); let x` throws first;
re-entering a block resets its bindings (`while (n < 2) { n++; if (n === 2) print(z); let z = 1; }`
throws on the second iteration); `const` TypeError for `=`, `+=`, `++` and in `for (const …; i++)`,
none for `if (false) c = 2`.
Surrogates: concatenating two lone halves gives one pair, printing a lone surrogate gives U+FFFD.
`-0` through arithmetic, comparison, compound assignment and string conversion. Evaluation order
(left before right, arguments before the call check, short-circuit side effects). Golden tables
from node for Number→String (3,183 values), String→Number and `+ - * / % **` on special values.
Limits: step budget on loops, straight-line code and deep expressions; heap and string limits;
allocation failure at every point; fuzzing of whole runs.
**M7:** `length` and `charCodeAt` on strings with surrogates.
**P1 (done):** two separate metrics, both permanent tests:
- *agreement with node*: 8,284 node cases; forced results bit-exact, all others within 1 ulp;
- *accuracy*: 7,942 correctly rounded reference values (`tools/pow_reference.py`); never more
  than 1 ulp from the true value, and at least 7,933 correctly rounded (today's count).
Reproducibility: `pow_data.zig` is generated (`tools/gen_pow_data.js`, pinned source hashes);
`zig build check-goldens` verifies tables and references are up to date; `zig build pow-bits`
hashes results per target for portability checks.
**M6:** per-iteration `for (let …)` bindings: closures created in the body must each see their
own iteration's value (`for (let i = 0; i < 3; i++) fs.push(() => i)` → 0, 1, 2), including when
the body or the update changes `i`.
**M6:** stack relocation: deep recursion forcing several moves, native→JS callback growing
the stack then reading its args, closure created before a move and called after it. Whole suite
under `-Dstack-stress`.
**M7:** property order: `0,1,b,a` example, `"4294967295"` vs `"4294967294"`, `"01"`, `"-1"`,
delete + re-add.
**M8:** GC rooting and atom lifetime: the targeted stress tests in DESIGN_DECISIONS D10 and
D11. Whole suite under `-Dgc-stress`. OOM injection over script runs.
