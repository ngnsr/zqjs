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
| 7 | Objects, arrays, atoms, ordered properties, prototypes | **done** |
| 8 | Mark-and-sweep GC: safepoints, precise roots, weak atoms, stress modes, heap verifier | **done** |
| 9 | Embedding API (handles, `NativeCtx`), then C ABI | – |
| 10 | Fuzzing all layers, benchmarks, Guard Malloc / Valgrind CI | – |
| 11 | Bytecode inspector/debugger: single-step, stack/frames, heap browser, manual GC, breakpoints | – |

## Technical debt
Known shortcuts, each with the decision that explains it and what would replace it.

| shortcut | where | replace with | when |
|---|---|---|---|
| tree-walker on its own 64 MiB thread (~14.5 MB of native stack in Debug at the depth limit) | D37, `src/interp/treewalk.zig` | an explicit interpreter stack: continuation records on the heap, no native recursion | when the tree-walker's memory or thread matters (embedding it), or before M10's benchmarks |
| tree-walker allocates every string literal on every evaluation | D30 | the VM's constant pool already fixes it; the oracle stays simple | not planned |
| VM panics on a failed defensive check instead of returning an internal error | D35 | an internal-error result, if an embedder needs to survive a VM bug | M9 (embedding API) |
| VM ~10-19% slower than at M6 on the M6 workloads (same steps), cause outside the VM loop | bench/baseline.txt, M7 notes below | profile the shared paths (ops, runtime layout) | before M10's benchmarks |
| one step allocating more than the room left can hit LimitExceeded(heap_bytes) while collectable garbage exists | D8 "Acknowledged limitation" | collect and retry at the safepoint (instruction-level) | M8.1, if a real program hits it |
| property names interned (hashed) on every access by name | `object.named` | atoms in the constant pool, then inline caches if benchmarks justify | M10 |

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
**M7 (done):** every item on both engines; (node) = a `tests/diff` program.
- evaluation order (node): base and computed key exactly once for `op=`, prefix/postfix `++`/`--`
  on named and computed members, plain assignment (base, key, right-hand side), computed
  literal keys (key then value), method calls keeping their receiver; key conversion after the
  right-hand side for `=` (a throwing key converts after `rhs` printed)
- objects (node): key order `0,1,2,b,a`; `"4294967294"` an index, `"4294967295"`, `"01"`, `"-1"`,
  `"1.5"` strings; delete + re-add moves to the end; number keys (`-0`, `1e21`); keywords as
  names; shorthand, methods, duplicate keys; `in`, `delete`
- arrays (node): index, length, append at the end, push/pop/join, truncation, nested arrays,
  named properties on arrays, cycles; RangeError for an invalid length; Unsupported for holes
  (`[1,,2]`, `delete a[1]`, writes past the end, growing length)
- prototypes (node): inherited reads, own writes, `in` along the chain, `Object.keys` own only,
  null prototypes, built-in methods not enumerable; no cycles (`__proto__` Unsupported)
- `this` (node + Unsupported cases): receiver of the call, not of the definition; a method
  borrowed by another object; a function nested in a method; native methods with a receiver;
  `const f = o.m; f()` and a plain inner call are `Unsupported(sloppy_this)`
- primitives (node): string `length`, `s[i]`, `charCodeAt` in UTF-16 code units with a surrogate
  pair; properties of numbers/booleans/strings via their prototypes
- conversions (node): `String`, `+`, `<` and keys of objects and arrays; user toString/valueOf/
  join are `Unsupported(user_conversion)`
- built-ins: implemented ones work; known ones are `Unsupported(builtin)` naming the member
  (`Math`, `[].map`, `'x'.toUpperCase`, `Object.assign`, `Object.name`, `constructor`,
  `hasOwnProperty`, `console`); unknown names stay `undefined` / ReferenceError; the inventory is
  node-generated and checked by `check-goldens`
- limits: heap (objects, properties, elements), string length of a join, conversion depth
- GC traceability: `forEachChild` enumerates every edge of every kind (unit test per kind)
- grammar: 38 node-checked syntax cases (literals, members, accessors and spread Unsupported,
  `?.`, `delete x`, `for…in` still Unsupported while `in` works elsewhere)
- verifier rules for the new instructions; bytecode snapshot `objects.js`; allocation failure
  with objects; differential fuzzing corpus with objects
- benchmarks: `objects.js`, `arrays.js` added; the six M6 workloads unchanged (steps identical;
  only `strings.js` allocates more: string headers now carry atom data). The VM *time* had
  regressed ~3×: `std.enums.fromInt` (a linear search) decoded every opcode, and `Op.info`
  (a big switch) ran on every instruction; both became table lookups, recovering most of it.
  ~10-19% remains vs M6, measured with both builds back to back; it is outside the VM loop
  (removing the new VM instructions doesn't change it). Listed under Technical debt.
**M8 (done):** stop-the-world, non-moving, precise mark-and-sweep (GC_DESIGN.md, D7-D11).
Every item on both engines unless noted.
- store API: every reference store goes through `heap.store*` (owner, old, new value; the future
  barrier hook); a source scan fails on any raw store and checks its own patterns
- collector: accounting exact after a sweep; a value reachable only through a chain of every
  object kind survives a collection that frees garbage of every kind around it; collection
  allocates nothing (run with the allocator failing every request); scheduling bounded
  (`next_gc = live + min(max(live, 256 KiB), (limit − live)/2)`; filling the heap with live
  data costs O(log limit) collections; the first formula made every safepoint collect near
  the limit, and fails this test)
- weak atoms: 10 000 keys kept by their object, dropped with it, a key reused after `delete`;
  only live atoms in the table after a collection; 20 000 dynamic keys on dropped objects leave
  the table small in a real run
- roots: one test per VM root kind (operand stack, locals, cells, frames' closures and `this`,
  Proto constants, the realm), the runtime's exception message and unsupported name, and one
  node-checked program per tree-walker shadow-stack site (calls, recursion, receivers,
  literals, returns, closures, per-iteration bindings), each collecting at every safepoint
- every `tests/diff` program matches node on each engine with a collection at every safepoint
- failures mid-evaluation and allocation failure at every point with collection forced; a
  failed, torn-down engine leaves no registration
- garbage under a small limit runs to the step budget (fails if an engine stops collecting);
  a program mixing garbage with a growing live structure checks the structure at the end
- `-Dgc-stress` (collect at every safepoint, tombstones naming kind and allocation number, the
  heap verifier after every collection): the whole suite passes in Debug and ReleaseSafe; a
  removed root gives the same `use of a collected <kind> (allocation #N)` panic on every run;
  the verifier catches each kind of corruption in a unit test
- benchmarks (`bench/baseline.txt`, against `bench/baseline-m7.txt`): steps identical on every
  row; peak heap down by up to 400× (tree-walker `loop.js` 104 MB → 262 KB); `collections`
  column added
- **kept permanently:** `-Dgc-stress` in CI (with `-Dstack-stress`, and in ReleaseSafe); the
  verifier as a development tool without stress (`zqjs --verify-heap`, `RunOptions.verify_heap`)
- **measured after M8** (ReleaseFast, Apple M4, a temporary timer around each collection, not
  committed: the runtime has no clock): on the eight benchmarks pauses are 30-90 µs, never
  above 1 ms, but collecting takes 15-37% of run time on garbage-heavy code (a collection every
  ~256 KB allocated); with 100k live objects (~45 MB) pauses reach 36-41 ms, with 1M (~450 MB)
  300-340 ms, and over half the run is spent re-marking long-lived objects. Pause time is
  linear in the live heap (~0.3 µs per live object).
- **direction from those numbers:** M8.1 generational (nursery, promotion, remembered sets: stop
  re-marking survivors), M8.2 incremental marking (bounded work per safepoint: caps the pause,
  including old-generation ones), M8.3 thresholds tuned on game workloads. First: a permanent
  GC report (allocation rate, mean/max pause, collections per second, live after GC, time
  collecting) with timing passed in by the tool, never in the runtime, and a game-like
  workload (100k and 1M long-lived objects, thousands of temporaries per frame, minor and major
  pauses measured separately). M9 (embedding) is not to wait for all of this.
