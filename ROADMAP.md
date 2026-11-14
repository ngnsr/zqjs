# Roadmap

Each milestone ships unit tests, golden/edge-case tests, a runnable demo and doc updates.
"Required regression tests" are acceptance criteria: the milestone isn't done without them.

| # | Milestone | Status |
|---|---|---|
| 1 | Lexer, Pratt parser for expressions, AST, diagnostics, `--dump-ast` | **done** |
| 2 | `let`/`const`, assignment, blocks, `if`/`while`/`for`, `break`/`continue`, resolver | **done** |
| 3 | Tree-walking interpreter, `runtime/ops.zig`, UTF-16 strings, `print`, diff harness | **done** |
| P1 | Accurate exponentiation: JS special cases, musl/Arm `pow`, accuracy and portability checks (D25) | **done** |
| 4 | Bytecode compiler, constant pool, `max_stack`, verifier, disassembler | **done** |
| 5 | Stack VM with `step()` / `--trace`, instruction budget | **done** |
| 6 | Functions, cells/closures, growable stack, call-depth limit | **done** |
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
**M5 (done):** the tree-walker is the oracle for the VM.
- every `tests/diff` program on both engines equals node's output (incl. the const/TDZ order
  programs and `unary_strings.js`, a regression test for a result-location aliasing bug)
- the engines agree (stdout, stderr incl. exception messages, exit code) on every syntax case
  and a corpus; differential fuzzing on arbitrary input; a mismatch report shows the source,
  both results and the VM's bytecode
- `step()` contract (D35): one instruction per call, budget charged first and never above the
  limit (no counter overflow at `maxInt(u64)`), precise faults (pc and stack as before the
  failing instruction: TDZ read, global miss, operator limit, native failure), nothing runs
  after halt or a fault, empty script (`max_stack` 0)
- limits on both engines (steps, heap, string length); allocation failure at every point on
  both engines, including the partial states of `Vm.init`; `--trace` format
**M4 (done):** the verifier (D33) is the oracle until the VM runs.
- every `tests/diff` program and every `ok` syntax case compiles to bytecode the verifier
  accepts, with the verifier's measured `max_stack` equal to the compiler's and no unreachable
  instructions (including code after `break`/`continue`, after `if` with both branches leaving,
  after `for (;;)` with and without `break`)
- verifier: one rejected example per rule (opcode, truncation, each operand kind, misaligned
  target, underflow, overflow of `max_stack`, non-empty stack at `halt`, falling off the end,
  inconsistent depth at a join, limits, non-number/string constants)
- `const`/TDZ evaluation order with observable right-hand sides, as programs whose node output is
  checked now (tree-walker) and again in M5 (VM): `c = rhs`, `c += rhs`, `c++`, TDZ `c = rhs` /
  `c += rhs`, a right-hand side that throws its own error first; plus the `tdz_and_const` snapshot
- constant pool dedup (`1`/`1.0`, `'a'`/`'\u0061'`), names dedup
- limits: `code_bytes`, `constants` (literals and names), heap and string limits on string
  constants; after any failed compile the heap is empty again (`Heap.rollback`)
- allocation failure at every point of compilation; fuzzing of compiler and verifier
- snapshots in `tests/bytecode` (`--dump-bytecode` listings)
**P1 (done):** two separate metrics, both permanent tests:
- *agreement with node*: 8,284 node cases; forced results bit-exact, all others within 1 ulp;
- *accuracy*: 7,942 correctly rounded reference values (`tools/pow_reference.py`); never more
  than 1 ulp from the true value, and at least 7,933 correctly rounded (today's count).
Reproducibility: `pow_data.zig` is generated (`tools/gen_pow_data.js`, pinned source hashes);
`zig build check-goldens` verifies tables and references are up to date; `zig build pow-bits`
hashes results per target for portability checks.
**M6 (done):** every item runs on both engines; programs marked (node) are `tests/diff` programs.
- per-iteration `for (let …)` (node): each iteration's closure sees its own value, including
  when the body or the update changes `i`, with `continue`, and a `const` head (no copies)
- closures (node): fresh captured bindings for every execution of a block (two sibling blocks;
  a `while` body run three times); two closures sharing one mutable variable that outlives the
  scope that created it; independent counter instances; a capture of a capture written
  through; a captured parameter; a closure over a later `let`, in its TDZ and after
- calls (node): recursion, mutual recursion through hoisting, call before declaration, a
  recursive named function expression whose name isn't visible outside, missing and extra
  arguments (evaluated, in order), `return` from nested blocks and loops, falling off the end,
  shadowing between parameters, locals and captured names, function identity, calling a
  non-function, assigning to a captured `const` (right-hand side first)
- grammar (node-checked classifications): 48 syntax cases (Annex B block functions, duplicate
  parameters/functions, `arguments`, default/rest parameters, generators, `async`, `return`
  outside functions, `break` across a function boundary, ASI after `return`)
- VM: precise fault inside a callee (frames intact); a call failing on a limit or on allocation
  leaves the caller unchanged; `return` restores the caller's pc, frame and operand depth
- limits: `call_depth` (both engines, including through a named expression and mutual
  recursion), `stack_slots` counts every frame (and the script's), `interpreter_depth`: measured
  stack use stays under half of the tree-walker's own 64 MiB stack in Debug and ReleaseSafe, and
  worst-case recursion from a 256 KiB host thread ends in LimitExceeded on both engines
- verifier: one test per new rule (capture descriptors, `halt`/`return`/`push_callee` placement,
  return depth, nested-proto kinds, tree-wide code size, malformed bytes after a jump)
- whole suite under `-Dstack-stress` (both stacks move on every call) and in ReleaseSafe, in CI
- allocation failure at every point with closures, cells, calls and per-iteration copies
- moved to the milestone that adds the first native able to call JS (with `NativeCtx`, D12): a
  native→JS callback that grows the stack, then reads its arguments
**M7:** property order: `0,1,b,a` example, `"4294967295"` vs `"4294967294"`, `"01"`, `"-1"`,
delete + re-add.
**M8:** GC rooting and atom lifetime: the targeted stress tests in DESIGN_DECISIONS D10 and
D11. Whole suite under `-Dgc-stress`. OOM injection over script runs.
