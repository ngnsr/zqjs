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
| 8.1 | Generational GC (non-moving): nursery, remembered set, array and property cards, adaptive major scheduling; GC report and game workloads (GC_DESIGN §15) | **done** |
| 8.2 | Incremental major marking | deferred (see Direction) |
| 9.0 | Zig embedding API: lifecycle, compile once / run many, execution under limits and step budgets, results instead of panics | **done** |
| 9.1 | GC-safe handles, native functions (`NativeFn`), JS callbacks from natives, error handling across the boundary | **done** |
| 9.2 | C ABI: header, opaque handles, error codes, a C example and integration tests in CI | – |
| D1 | Demo (separate project, not a dependency): a Raylib game whose logic is a ZQJS script | – |
| 10 | Fuzzing all layers, benchmarks, Guard Malloc / Valgrind CI | – |
| 11 | Bytecode inspector/debugger: single-step, stack/frames, heap browser, manual GC, breakpoints | – |

## Direction after M8.1 (reviewed 2026-11-15)

**What ZQJS is for.** A small, controllable, embeddable scripting engine: a host (Zig, C, C++)
owns rendering, input, physics and resources, and runs script logic under limits it sets. It
isn't a Node.js clone. Features are judged by whether an embedder needs them.

**Why embedding comes next.** Until a host can call ZQJS, register natives and keep values,
every other improvement only optimizes a standalone interpreter. Embedding is also what tells us:
- which language features scripts actually need;
- which paths are hot;
- whether major GC pauses matter in practice.

M9 is split into M9.0, M9.1 and M9.2, so that each step is usable on its own. The Raylib demo
(D1) then proves it in a real application.

**M9.0 keeps the VM private.** The public Zig API exposes only engine-level types (a
runtime, a compiled program, values through handles, results). `Proto`, heap internals, stack
layout and GC details stay private, so a VM or collector change never breaks an embedder.

**M9.1 handles need their own design pass**, approved before implementation, like M8.1's. Once
a host can retain JS values, ownership and lifetime are public API. These need precise
semantics:
- stale and released handles;
- re-entrant callbacks (a native calling JS calling a native);
- allocation failure at every boundary crossing.

**Deliberately not yet**, each waiting for a measured need:

| what | why it waits | until |
|---|---|---|
| VM performance work | 6.3 ns per instruction on `loop.js` (M8 baseline, M4) is the baseline to beat; claims against other engines need a reproducible comparison harness first | M10 |
| inline caches | profiling must first show property access is the bottleneck, after atoms in the constant pool | after profiling |
| incremental GC (M8.2) | minor collections are ~0.05 ms; the 46 ms majors (1M objects) happen while live data grows, not in steady frame loops | an embedder hits them |
| promises, microtasks, async/await, modules | the host owns the event loop; embedding defines it first | after M9 |
| classes and `new`, regex, JSON, generators | not needed for embedding | an embedder needs them |
| JIT or AOT | the interpreter isn't optimized yet; JIT is forbidden on iOS and consoles, the game-scripting targets | not planned |
| more than one thread per runtime | | not planned |

The language floor (try/catch/throw first, `?:`, `Math`, a few string and array methods) is
sized by what the demo actually needs.

## Technical debt
Known shortcuts, each with the decision that explains it and what would replace it.

| shortcut | where | replace with | when |
|---|---|---|---|
| tree-walker on its own 64 MiB thread (~14.5 MB of native stack in Debug at the depth limit) | D37, `src/interp/treewalk.zig` | an explicit interpreter stack: continuation records on the heap, no native recursion | when the tree-walker's memory or thread matters (embedding it), or before M10's benchmarks |
| tree-walker allocates every string literal on every evaluation | D30 | the VM's constant pool already fixes it; the oracle stays simple | not planned |
| VM panics on a failed defensive check instead of returning an internal error | D35 | an internal-error result, if an embedder needs to survive a VM bug | M9 (embedding API) |
| VM ~10-19% slower than at M6 on the M6 workloads (same steps), cause outside the VM loop | bench/baseline.txt, M7 notes below | profile the shared paths (ops, runtime layout) | before M10's benchmarks |
| one step allocating more than the room left can hit LimitExceeded(heap_bytes) while collectable garbage exists | D8 "Acknowledged limitation"; bounded by D44's HL2: a step allocating at most half the room above the old generation never fails | collect and retry at the safepoint (instruction-level) | M9, if an embedder hits it |
| tree-walker 2-6% slower than at M8 (closures, objects, fib, scopes; same steps; the VM is unchanged or faster) | `bench/baseline.txt` vs `bench/baseline-m8-smp.txt`; probably the barrier on every environment store | profile; the tree-walker is the oracle, not the shipped engine | when it matters (M10) |
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
**M8.1 (done):** generational, non-moving collection (GC_DESIGN §15, D42–D45). Every item
runs on both engines unless noted.

*Measurement first:*
- a heap observer (the clock is passed in by the tool, never kept in the runtime);
- `zig build gc-report`: 5 runs per row, medians with their spread, pause buckets, minor and
  major collections separately, the remembered-set scan time, and peak memory;
- game-like workloads in `bench/gc/`: 100k and 1M persistent entities, a growing set, a 1M
  array and a 200k-entry dictionary that each take one young store per frame;
- an M8 baseline taken before any change.

*Collector:*
- minor collections never trace old objects;
- promotion on first survival: after any collection the nursery, the remembered set and every
  card are empty (I-gen3);
- a minor collection never frees an atom (promotion is not marking: a dead object keyed by a
  dead atom is still freed);
- a major collection rebuilds the atom table before freeing, and sweeps old before young.

*Verifier:*
- I-gen1–4: the lists, every old-to-young edge checked independently of the bitmaps, the
  remembered list well formed, and I-gen3;
- run before and after every collection under stress;
- `zig build gc-mutants` (in CI): 8 broken builds, each caught by the verifier. They are: the
  element barrier, the card set, the remembered bit, the first array bitmap, the minor
  collection freeing atoms, the property card set, the delete dirtying, and the first property
  bitmap.

*Cards:*
- array and property cards at boundaries 0, 511, 512, 1023, 1024 and the last;
- the hole case (remembered before the first bitmap);
- bitmap growth over reallocations;
- deletes at the start, middle and end, shifting young entries across cards;
- pop and shrink;
- allocation failure while a bitmap grows;
- the bitmap freed with its object in a minor and in a major collection;
- a young key with an old value.

*Scheduling:*
- the nursery size from a 256K–4M sweep;
- adaptive majors (D44) with T1, the adaptation cycle, the T2 burst simulator (which fails
  if the minor trigger ignores the half room) and T3 programs;
- dead dynamic keys drive major collections under a 1 MiB limit (fails if the growth trigger
  is ignored).

*Results* (`bench/gc/baseline-m8.txt` vs `baseline-m8.1-libc.txt`, the same allocator; VM):

| workload | GC share, M8 → M8.1 | p95 pause → minor p95 | major collections | longest major |
|---|---|---|---|---|
| game_100k | 41% → 17% | 39 → 0.06 ms | 16 → 3 | 39 → 0.7 ms |
| game_1m | 56% → 22% | 283 → 0.06 ms | 12 → 5 | 283 → 68 ms |
| game_growing | 37% → 17% | 58 → 0.06 ms | 27 → 6 | 85 → 12 ms |

- On smp_allocator, GC share falls further: to 4%, 15% and 6%.
- `bench`: steps identical on every row. VM time is unchanged or faster. The tree-walker is
  2–6% slower (in the debt table).

*Tests got faster:*
- one binary per test file, run in parallel;
- program-sized tests on a leak-checking allocator without stack traces;
- a watchdog per test binary;
- the suite went from ~160 s to ~17 s, and CI runs one parallel job per configuration.

**M9.0 (done)**
- **Public surface pinned:** `zqjs` is the sole module exported to embedders; snapshot test prevents accidental exports (D46).
- **Lifecycle (E1):** leak-free create and destroy; `Runtime.destroy` reclaims all live programs and executions; programs compiled but never run leave no leak; `Program.destroy` releases constants after collections once all executions terminate.
- **Atomic entry guard (E2):** single-threaded runtime enforcement; CAS entry guard prevents overlapping calls and catches re-entrant host calls.
- **Cooperative executions & step budgets (E4, E5):** slice execution yields `.suspended`; cumulative per-execution cap halts runaway scripts; ties yield `.suspended` before faulting; multiple executions maintain isolated frames and stacks while sharing realm state.
- **Slices change nothing:** differential test programs produce node-identical outputs with slices of 1, 7, 1000, and unbounded steps under GC collections.
- **Failure text rules (E10):** non-allocating, guaranteed UTF-8, truncated at code point boundaries with `…`, surrogate pairs preserved, lone surrogates converted to U+FFFD.
- **Internal errors (E7, D49):** defensive VM checks return `error.Internal` and poison the runtime instead of panicking; proven with a hand-corrupted proto through `zqjs_internal`. The verifier rejection path poisons too; the CLI reports `internal error: <reason>` (exit 70).
- **Use after destroy (E1):** safe builds tag-check every entry point; `Program.destroy` with live executions is caught deterministically via the handle flag. Expected panics (guard re-entrancy from a writer, `Runtime.destroy` from a writer, two threads on one runtime, a program used after destroy) run as child processes in `tests/api_test.zig`.
- **Runnable example:** `examples/embed.zig` (`zig build example`) demonstrating two interleaved executions stepping across frames.

**M9.1 (done)**
- **GC-safe handles (D50, D54):** reference-counted handle-table slots traced as GC roots; generation-checked tokens (`newNumber`, `newBoolean`, `newStringUtf16`, `kind`, `number`, `boolean`, non-allocating `string(buf)` returning full UTF-16 length, `dup`, `release`); cumulative `Limits.max_handles` pool cap accounted in `memory().bytes`; deterministic child-process panics on use-after-release and cross-runtime handle misuse.
- **Model B re-entrancy & shared execution context (D51):** `Runtime.call` and host native callbacks execute nested JS closures on separate nested VMs sharing the runtime's heap and realm while outer VMs stay suspended mid-instruction with their roots registered; one cumulative `max_steps` budget (with latched `budget_fault` that callbacks cannot clear or replace), one shared `max_call_depth` counter, and cooperative slice overshoot across synchronous native chains.
- **Guard entry-kind stack & callback capability (D52):** sanctioned re-entrant calls (`call`, `new*`, `dup`, `release`, handle readers, `throwJs`, `collectGarbage`, `memory`) descend via the active `NativeRecord` on the owner thread; `compile`, `start`, and `run` inside a callback return `error.Busy`; unsanctioned host re-entry (`resume`, `defineGlobalFunction`, `Program.destroy`), writer re-entry during nested `print`, and cross-thread access panic.
- **Host natives & 3-way handle ownership (D53):** `defineGlobalFunction` registers realm-persistent host natives (rejecting duplicates and built-in names with `error.NameTaken`), passes temporary callback-scoped `this` (object receivers only, D41) and `args` tokens, transfers `NativeOut.result` token ownership to the engine (preserving the release-order invariant and releasing `out.result` across all success and error paths), requires `dup()` when returning host-retained handles, and supports `throwJs` (`Failure.Kind.thrown`) and non-poisoning `error.HostError` (`Failure.Kind.host`).
- **R1, R2, and allocation-failure proofs:** R1 (nested JS stack reallocation + closures under `-Dstack-stress`), R2 (retained object handle surviving nested JS GC churn + explicit `collectGarbage` under `-Dgc-stress` across success and failure paths), 3-level `JS -> native -> JS -> native -> JS` round trips, and `checkAllAllocationFailures` across handle creation, `Runtime.call`, `defineGlobalFunction`, and callback round trips.

**M9.2 (done)**
- **Standalone C11 ABI & C++17 header:** `include/zqjs.h` + `libzqjs.a` (`src/c_api.zig`), libc-independent (`std.heap.smp_allocator`), `_Static_assert` layout checks and external C/C++ consumer example (`examples/c_embed.c`).
- **Zero-panic C boundary:** every C entry point returns `zqjs_status`; null/invalid args, stale/foreign handles, destroyed wrappers, and disallowed re-entrancy return deterministic status codes instead of panicking.
- **C11 integration tests (`tests/c_api_test.c`):** lifecycle (including destroying `Program` while `Execution` is `.suspended` and destroying `Runtime` with live children), slot reuse, cross-runtime handles, native callbacks, `throw_js` vs `HostError`, round trips, and GC during callbacks.

**M10 (done)**
- **M10.0 (historical baseline, tag `m10.0`):** added `bench/m10/js/` (11 pure-JS workloads with exact/explicit parity rules against QuickJS `2026-06-04` and Node), split-phase `tools/m10_bench.zig` (`compile` vs `exec` vs direct `total` within the same sample), `tools/m10_c_bench.c` (C-ABI native throughput and 30×3,600 frame distribution with `CLOCK_THREAD_CPUTIME_ID` outlier diagnosis), and `tools/m10_compare.py`; initial measurements preserved in `bench/m10/baseline-qjs-initial.md`.
- **M10.1 (profiling):** macOS `sample` profiles of `global_reads.js`, `int_loop.js`, and `float_math.js` identified `Vm.step()` per-instruction dispatch overhead, `ops.binary`/`ops.toNumber` generic numeric dispatch, and `libm` `fmod` on `%` as the dominant bottlenecks.
- **M10.2a–c (targeted optimizations, tags `m10.2a`, `m10.2b`, `m10.2c`):**
  - `m10.2a`: continuous `Vm.runLoop()` shared by `Vm.run()`, `Vm.runSteps()`, `ExecutionImpl.resumeImpl()`, and `callImpl()`, keeping `Vm.step()` unchanged for single-stepping/tracing.
  - `m10.2b`: inline two-`.number` fast paths in `vm.zig` preserving IEEE-754 `NaN`, infinities, and `-0`.
  - `m10.2c`: `fastRemainder` for safe integral `%` preserving dividend sign and `-0` (`-4 % 2`, `-0 % 5`), verified differentially against Node.
- **M10.3 (checkpoint baseline):** CLI-to-QuickJS ratios improved across all 11 benchmarks (`int_loop.js` `6.28x -> 3.75x`, `global_reads.js` `7.37x -> 4.71x`, `float_math.js` `6.73x -> 3.86x`, `closures.js` `1.64x -> 1.22x`), C-ABI native calls reached `~5.05M–5.41M calls/s`, and `bench/baseline.txt` + `bench/m10/baseline-qjs.md` recorded the post-M10.2c checkpoint.
- **M10.4 (profiling-led dispatch & atom caching, tags `m10.4b`, `m10.4c`):**
  - `m10.4a` (rejected & reverted): forced `inline` on `push`/`value`/`peek`/`target` regressed performance due to code bloat.
  - `m10.4b`: pre-interned weak `Proto.name_atoms` (`Proto.deinit` frees slice only, `Heap.rollback` & `Heap.collect` sweep empty `h.atoms`, `Vm.nameKey` reads `a.atom.?.index` dynamically).
  - `m10.4c`: direct `Op` bounds check (`@fromBackingInt`, eliminating `?Op` stack spill) + loop-local `FrameCache` (`p`, `code`, `pc`), keeping `vm.pc` synchronized on every committed instruction.
- **M10.5 (interpreter & runtime fast paths, tags `m10.5a`, `m10.5b`, `m10.5c`, `m10.5d`):**
  - `m10.5a`: cached frame-constant `stack_base`, `stack_limit`, and `locals_base` (index-only) in `FrameCache` + `noinline` `@branchHint(.cold)` on `Vm.bug`, allowing LLVM to inline stack accessors without `m10.4a` code bloat.
  - `m10.5b`: cold `growFrames`/`reserve` guards in `Vm.enter` and slice-based `initLocals` (verified against `verify.zig` `param_slot + param_count <= slot_count`).
  - `m10.5c`: lazy `builtins.realm(rt)` in `object.get` + dense-array `fastArrayGet` in `.get_elem` (`-0` → `0`, finite non-negative integer `< elems.len`).
  - `m10.5d`: cached `FrameCache.sp` synced via `syncSp` at GC safepoints, native/closure calls, returns, error exits, and bounded `runSteps` exits (invariant: no code outside `execute` may observe stale `vm.sp`), cutting `vm.sp` memory accesses in `resumeImpl` from `79` to `10`.
- **Final M10 checkpoint (`05c0c7a`):** CLI-to-QuickJS improved across all 11 workloads vs `m10.0` (`arrays.js` `5.39x -> 2.23x`, `branch_dense.js` `4.99x -> 1.90x`, `call_chain.js` `5.96x -> 2.33x`, `closures.js` `1.64x -> 0.75x`, `fib.js` `4.37x -> 1.74x`, `float_math.js` `6.73x -> 2.20x`, `global_reads.js` `7.37x -> 2.71x`, `int_loop.js` `6.28x -> 2.10x`, `objects.js` `3.53x -> 1.66x`, `scopes.js` `6.23x -> 2.52x`, `strings.js` `3.21x -> 2.31x`); C-ABI reached `~6.59M calls/s` (`js_to_c_native`), `~4.87M trips/s` (`host_js_c_js_roundtrip`), and `65.988 ms` (`frame_p50 = 18.00 us`) on `frame_loop_3600`. Remaining QuickJS gap (`~1.66x–2.71x` on loop/property workloads) sits in the `switch`-based bytecode interpreter loop (`rt.step()`, safepoint check, jump-table dispatch) and uncached `get_prop`/`set_elem` paths (deferred until M11+ if needed).

**M11 (done — Language & Embedding Floor)**
- **M11.1 (done, tag `m11.1`):** conditional expressions (`?:`), right-associative between `||` and assignment, lowered to `jump_if_false` + `jump` (no new VM opcodes), with syntax and Node-differential tests on both engines.
- **M11.2 (done, tag `m11.2`):** `throw expr` and `try { ... } catch [(e)] { ... }` (`finally` deferred as `Unsupported`), `Runtime.thrown_value` + `{ name, message }` materialization for native/runtime errors, two-phase `Vm.unwind` preserving uncaught fault state and `FrameCache`, tree-walker `execTry`, and Node-differential + `JS → native → JS` + uncatchable-limit tests.
- **M11.3a (done, tag `m11.3a`):** `Math` built-in object (8 standard constants + 24 functions including `abs`, `floor`, `ceil`, `round`, `trunc`, `min`, `max`, `pow`, `sqrt`, trig/log/exp, `sign`, `clz32`, `imul`, `fround`, `hypot`, `random`), per-runtime deterministic `Runtime.rng` seeded via `Options.random_seed` (not cryptographically secure), `Unsupported(builtin)` for unimplemented `Math` members, and Node-differential + seeding tests.
- **M11.3b (done, tag `m11.3b`):** core `Array.prototype` (`push`, `pop`, `slice`, `indexOf`, `includes`, `join`) and `String.prototype` (`charAt`, `slice`, `indexOf`, `includes`, `toLowerCase`, `toUpperCase`) methods with UTF-16 indexing, negative/relative index clamping, strict equality (`indexOf`) vs SameValueZero (`includes`), and argument string coercion. Compatibility restrictions: `toLowerCase`/`toUpperCase` are ASCII-only (`Unsupported(builtin)` on non-ASCII `>= 0x80`), `slice()` always returns a dense array (holes rejected at creation as `Unsupported(sparse_array)`), and callback-taking array methods (`map`, `forEach`, etc.) remain out of scope.
- **M11.4 (done, tag `m11.4`):** C11 Raylib embedding demo (`examples/raylib_c_demo.c`) linking `libzqjs.a` + `zqjs.h` + Raylib (optional; `zig build` and `zig build test` stay Raylib-free). JS owns game logic (`update(dt)` / `draw()`, exercising `Math`, `Array`, `String`, `try/catch`); C owns the frame loop, native bindings, and clean error reporting/teardown. Smoke tests: `zig build raylib-smoke` and `zig build raylib-smoke -Doptimize=ReleaseSafe` (`--frames 60 --verify-errors`, headless); interactive GUI (`zig build raylib-demo`) was not launched in the headless verification environment.

**M12 (done — Embedding Maturity)**
- **M12.1–M12.2 (done, tag `m12.2`):** API design/ownership contract and Zig API implementation (`Runtime.newObject`, `newArray`, `getGlobal`, `getProperty`/`setProperty`, `getIndex`/`setIndex`) preserving E3 fresh script bindings, D13 dense arrays, owned-return / borrowed-input handle rules, and `checkAllAllocationFailures` + child-process panic coverage.
- **M12.3 (done, tag `m12.3`):** C ABI versioning (`ZQJS_ABI_VERSION` `1.1.0`, `zqjs_abi_version()`), `zqjs_options.struct_size` backward-compatibility rules, `random_seed` parity, and C wrappers (`zqjs_new_object`, `zqjs_new_array`, `zqjs_runtime_get_global`, `zqjs_handle_get_property`/`set_property`, `zqjs_handle_get_index`/`set_index`) tested in C11.
- **M12.4 (done, tag `m12.4`):** Migrated `examples/raylib_c_demo.c` to ABI version check, `initGame({ update, draw, state })`, nested object/array inspection/mutation, and per-frame `{ dt, spaceDown }` handles with zero leaks.
- **M12.5 (done):** Updated `EMBEDDING.md` and `README.md` with ABI versioning, `zqjs_options.struct_size` rules, structured handle examples, and Raylib GUI/headless prerequisites; verified full Debug/ReleaseSafe/stress test matrix and `raylib-smoke` (interactive GUI not launched in headless environment).

**M13 (done, tag `m13` — Real-World Host Integration)**
- **M13.1–M13.3 (done, tag `m13`):** Added dependency-free C11 multi-plugin cooperative host (`examples/plugin_host.c`, wired into `zig build test` and `zig build plugin-host`) running 4 interleaved `zqjs_execution`s (`SLICE_STEPS = 48`) on one `zqjs_runtime` with deterministic `random_seed`, structured C ↔ JS objects/arrays (`fetchTask`/`submitOutput`), `Math`/`Array`/`String`/`try/catch`, latched uncaught-exception and `max_steps` fault containment, isolated-runtime `max_heap_bytes` recovery after execution teardown + GC, and 20-cycle memory/handle stability (`end_mem.handle_bytes == base_mem.handle_bytes`; `end_mem.bytes <= base_mem.bytes + 256` is a workload-specific stability bound, not a general exact-return guarantee). Compatibility boundary: shared-runtime multi-execution provides execution-level fault containment for trusted scripts, not security or per-plugin heap isolation. Verified across `zig fmt --check .`, `zig build plugin-host`, `zig build test --summary all` (30/30 steps), `ReleaseSafe`, `-Dgc-stress -Dstack-stress`, and `gc-mutants`.
