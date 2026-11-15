# Design decisions

Each entry records **what** we decided, **why**, the **alternatives** we rejected, and the
**consequences** we accept. Entries marked *(planned)* describe milestones that are not built
yet; they are written down now because they constrain earlier code.

---

## D1. AST before bytecode
**Decision.** Source → tokens → AST → (resolver) → bytecode. QuickJS emits bytecode straight
from the parser; we do not.
**Why.** Inspectability (`--dump-ast`), separate passes (scope resolution needs to know which
variables are captured before code is emitted, see D10), and a tree-walking oracle (D16).
**Cost.** An extra pass and the memory for the tree (bounded by source size, freed after
compilation, see D2).

## D2. Frontend memory: one arena per compilation
**Decision.** Tokens are not stored (the lexer is pull-based and allocation-free). AST nodes and
decoded string literals are allocated from an `ArenaAllocator` the caller provides, and freed in
one `deinit`.
**Rule.** No pointer into the arena may escape it. Anything that must outlive compilation
(constants, function protos) is *copied* into the runtime heap by the compiler.
**Why.** No ownership bookkeeping per node, no leaks possible, trivial error paths: on any error
the caller just deinits the arena. Allocation-failure paths are tested exhaustively with
`std.testing.checkAllAllocationFailures`.

## D3. AST nodes are pointer-linked, each node records its depth
**Decision.** `Expr` nodes are arena-allocated structs linked by `*const Expr`.
**Alternative.** Index-based flat arrays (`MultiArrayList`, as the Zig compiler does): more
cache-friendly and smaller, but harder to read and debug. We optimise for learning; the
AST is short-lived.
**Depth.** Every node stores `depth` (1 + deepest child). The parser rejects trees deeper than
`Limits.max_nesting_depth`. Without this, `1+1+1+…` (parsed by a *loop*, not recursion)
would build a 100 000-deep tree and later recursive passes (dumper, compiler) would overflow
the native stack. The parser's own recursion (e.g. `((((1))))`, which creates no nodes) is
bounded by the same limit.

## D4. Parse errors: first error wins, no recovery
**Decision.** The parser stops at the first problem and fills a `Diagnostic` (kind, span,
feature). No error recovery.
**Why.** Recovery is a large, separate topic and only matters for IDE-style tooling.
Messages are rendered from the span + source at print time, so diagnostics allocate nothing.

## D5. Values: tagged union
`union(enum) { undefined, null, boolean, number: f64, object: *Obj }` (16 bytes). Safe builds
check the active tag; debuggers can read it. Only `value.zig` knows the layout (accessors
everywhere else), so NaN-boxing remains a local change. *(planned, M3)*

## D6. Strings: UTF-16 code units
**Decision.** Runtime strings are immutable `[]const u16`.

| | UTF-8 | WTF-8 | **UTF-16** | Latin-1/UTF-16 dual |
|---|---|---|---|---|
| lone surrogates | ✗ | ✓ | ✓ | ✓ |
| `length`, `charCodeAt` | O(n), wrong | O(n) | **O(1), exact** | O(1) |
| concatenation | simple | must merge surrogate halves at the seam | simple | 2 code paths |
| ASCII memory | 1× | 1× | 2× | 1× |

**Why.** The only option that is both simple and exactly JavaScript's model.
**Consequences.** Source is UTF-8, so the parser decodes literals to UTF-16 (M1). Printing and
the host API convert at the boundary (lone surrogates → U+FFFD on output, as node does).
A Latin-1 representation can be added later behind the `String` API if memory matters.

## D7. Heap: one allocation interface *(M3; counting `allocator()` M7; revised for M8, GC_DESIGN §5)*
**Decision.** `runtime/heap.zig` is the only code that allocates runtime objects or touches the
runtime's backing allocator for them: the `new*` constructors for heap objects, and
`heap.allocator()`, a counting `std.mem.Allocator` for object-internal buffers (property tables,
element lists, the atom table), which charges the same `max_heap_bytes` (D28, D38).
**Revised for M8: allocation never collects.** The original plan made `heap.new` the only
safepoint, so any allocation could run a collection. M8 instead collects only at *safepoints*
(the start of a VM instruction, the start of a tree-walker evaluation; D8). An allocation only
adds to the allocation debt: past `next_gc` it sets `collect_requested`, and the next safepoint
collects. *Why:* with collection inside allocation, every heap pointer held in a Zig local across
any allocation needs a temporary root: dozens of sites in `object.zig`, `join`, every native,
both engines and the compiler, each a use-after-free when missed. Safepoint-only collection
leaves exactly one place that holds values across a safepoint: the tree-walker (D10).
*Cost:* garbage made within one step can't be collected before the step ends (bounded; D8).

## D8. GC: non-moving, precise, stop-the-world mark-and-sweep, at safepoints *(M8; generational since M8.1, D42–D44; GC_DESIGN)*
**M8.1 revision.** Collections are minor or major (D42), and the trigger is
`next_gc = B + min(nursery_bytes, (limit − B)/2)` after every collection, where `B` is the
heap left by that collection. The formula below (`next_gc = live + …`) became the
*major*-collection threshold `next_major`, adapted by D44. Everything else here holds for
both kinds: safepoints, roots, phases, no allocation while collecting, and deterministic
statistics.
**The safepoint contract.** No collection can occur during instruction execution (or during a
tree-walker evaluation step): every GC-managed reference an instruction needs is either
reachable from the root set at the safepoint that started it, or was allocated after that
safepoint. An instruction may therefore hold heap pointers in Zig locals freely.
**Object header.** `Obj { kind, next, marked, gray_next }` (+8 bytes per object): `next` links
every object (the sweep list), `gray_next` the gray worklist (D9). Every constructor leaves the
object fully traceable before returning.
**Phases.** At a safepoint with `collect_requested` (or forced: tests, `-Dgc-stress`): mark the
roots; drain the gray list through `heap.forEachChild` (D38); remove unmarked atoms from the
atom table (D11); sweep the object list, destroying unmarked objects and clearing survivors'
marks; schedule `next_gc = live + min(max(live, 256 KiB), (limit − live) / 2)`; update the statistics
(`collections`, bytes freed, live after, `marked`, `swept`: deterministic work units, no clock).
**Roots** (GC_DESIGN §4): `Runtime.realm`, `exception.message`, `unsupported_name`; the registered
Proto tree being run (its string constants; Protos are not heap objects); the VM's operand stack,
locals (values and cells) and frames (closure, `this`); the tree-walker's shadow stack, current
environment, `this` and pending return value; host handles (M9). The atom table is not a root.
**Compiler.** It runs before execution, with no safepoint inside, so its constants need no GC
pause and no rooting; `runSource` registers the finished Proto tree before running it.
**Heap limit and scheduling.** `max_heap_bytes` counts live data plus garbage not yet
collected. The trigger grows by the live size (at least 256 KiB), but never beyond half the
room left under the limit. *Revised in P1:* the approved design capped it at `limit − limit/8`,
which, once live data passed that cap, set the trigger below the heap size, so every following
safepoint collected again (quadratic slowdown near the limit; a test with the old formula
shows it). With the half-the-room rule, a program filling its heap with live data collects
O(log limit) times. *Acknowledged limitation:* because allocation never
collects, one step that allocates more than the remaining headroom can fail with
LimitExceeded(heap_bytes) although collectable garbage exists; the guarantee is "live +
headroom + one step's allocation". Accepted for M8 (GC_DESIGN §5); an instruction-level
collect-and-retry belongs to M8.1, not collection inside allocation.
**Barriers.** Every reference store into an existing heap object goes through the heap's store
API (`storeProperty`, `defineProperty`, `removeProperty`, `appendElement(s)`, `storeElement`,
`shrinkElements`, `popElement`, `storeCell`, `storeEnv`), each knowing owner, old and new value;
`tests/gc_test.zig` scans the sources for raw stores. The barrier is a no-op in M8 (no store can
happen during a stop-the-world collection); M8.1 (incremental) and M8.2 (generations) change only
what it does (GC_DESIGN §7, §13).
**Debug and stress.** `-Dgc-stress` collects at *every* safepoint (never less often: a lower
frequency hides exactly the missing roots it exists to find). Zombie mode keeps freed objects
as poisoned tombstones (`kind = .dead`) that every accessor rejects; a heap verifier runs after
each collection. Both in CI.
*Not planned:* moving or compacting (M8.3 research), finalizers, concurrent marking (later, if
benchmarks justify it).

## D9. GC worklist: intrusive gray list, no allocation during GC *(M8, unchanged by the M8 review)*
The collector must never fail halfway through marking.

| option | extra memory | can fail during GC? | complexity |
|---|---|---|---|
| growable gray stack (clox) | O(gray) | **yes** (OOM) | low |
| v2 plan: on OOM, set `overflowed`, rescan whole heap | O(gray) | no | medium; worst case O(heap × rounds) |
| gray stack preallocated to object count | 8 B/object, reserved at `heap.new` | no | medium; capacity management |
| pointer reversal (Deutsch–Schorr–Waite) | 0 | no | high; very hard to debug |
| **intrusive list (`gray_next` in header)** | **8 B/object** | **no** | **low** |

**Decision.** Intrusive gray list, as Lua does with its `gclist` field. An object is marked at
the moment it is pushed, so it enters the list at most once. Marking pops an object, iterates its
children (a loop, never recursion), and pushes unmarked children. There is no allocation and
no recursion, so neither OOM nor deep structures can break marking.
**Cost.** 8 bytes per object (header 24 B instead of 16 B). We accept it for a guarantee that is
obvious by construction.

## D10. Rooting discipline *(revised for M8: GC_DESIGN §4, §5)*
**Invariant.** At a safepoint, every value the program can still use is reachable from a root.
Because collection happens only at safepoints (D7, D8), this has to be arranged in exactly two
places:
- **The VM:** by construction. Every live value sits in its operand stack, locals or frames,
  which are roots, at each instruction start. Natives, `object.zig`, the compiler and the
  verifier contain no safepoint, so they need no rooting at all; whatever they allocate is
  returned into the VM's stacks or is garbage.
- **The tree-walker:** it holds values in Zig locals while it recurses into sub-evaluations,
  which contain safepoints. Each such value (or environment record) is pushed on its shadow
  stack before the sub-evaluation and popped with `defer`, so the stack is balanced on every
  exit path: normal return, Thrown, Unsupported, LimitExceeded and allocation failure. The ~15
  sites are listed in GC_DESIGN §4; a stress-build assertion checks the balance after every
  `exec`/`eval`, and per-site tests collect while the shadow stack holds the only reference.
**Replaced.** The original plan (temporary roots via `tempMark`/`pushTemp` in all runtime code,
rooting partially constructed objects and nested constructors, `errdefer` restrictions after a
collecting allocation) existed only because any allocation could collect. With safepoint-only
collection none of it is needed outside the tree-walker. Exceptions keep their rule: the message
is stored in `Runtime.exception` (a root) before `error.Thrown` is returned.
**Stress tests (M8, under `-Dgc-stress`):** array literals of fresh objects, nested object
literals, string concatenation in a loop, closures capturing cells in a loop, an exception thrown
mid-evaluation (shadow stack balanced afterwards), every allocation failing once.

## D11. Atoms (interned property names) and the weak atom table *(atoms M7; weak table M8)*
**Decision.** Property keys are atoms: interned `String` objects, compared by pointer. The
intern table is **weak**: it never keeps an atom alive.
**How keys stay alive.** Only through strong references: an object's property table marks its
*keys* as well as its values (`forEachChild`, D38), and `Runtime.unsupported_name` is a root.
After marking and before sweeping, unmarked atoms are removed from the table in place, so it
never holds a dangling pointer and cleanup needs no allocation.
**Revised for M8: bytecode keeps no atoms alive.** The original plan had a proto mark the atoms
its bytecode uses. It doesn't need to: bytecode stores property names as plain ASCII
(`Proto.names`) and interns them on use, and an atom freed in between is simply interned again
(atoms are looked up by content).
**Why weak.** A strong table leaks every dynamically generated key (`o["k" + i]`).
**Cached data.** Each atom caches whether it is a canonical array index (D13); hashing is by
content (FNV-1a over code units, D38).
**Regression tests (M8).**
- 10 000 keys `"k"+i` set on one object, collect 5×, read all back (keys kept alive by the object)
- same keys, object dropped, collect: the intern table shrinks to its baseline
- `delete o[k]`, collect, reuse `k`: a fresh atom works as the key again
- a property name used only by bytecode (`o.someName`) works across collections that freed its atom
- atom-table cleanup runs before the sweep (verifier: no table entry points at a tombstone)

## D12. VM stack: growable, addressed by index *(M5/M6; two stacks since M6, see D36)*
- `stack: []Value`, `sp: u32`; frames store `base: u32`, never pointers.
- The compiler computes `max_stack` per function. On entry the VM ensures
  `sp + max_stack ≤ capacity`, growing (realloc) up to `Limits.max_stack_slots`, else
  `LimitExceeded`. Pushes inside a function need no bounds check.
- Natives read arguments through `NativeCtx.arg(i)` (index into the stack), because a native
  that calls back into JS may cause the stack to move, which would leave a `[]Value` slice
  pointing at freed memory.
- `-Dstack-stress` moves the stack to a fresh allocation on *every* function entry.
**Regression tests (M6).** deep recursion that forces several moves; native→JS callback that
grows the stack, then reads its args; closure created before a move and called after it.

## D13. Object properties: insertion-ordered map + spec key order *(M7)*
`std.ArrayHashMapUnmanaged(*Atom, Property)` keeps insertion order. `delete` uses
`orderedRemove` (O(n), acceptable). `ownKeys()` yields array-index keys (canonical numeric
strings ≤ 2³²−2) ascending, then other string keys in insertion order. No hidden classes.
Arrays are dense; creating a hole is `Unsupported(sparse_array)` (D14). *M7:* that covers
`[1,,2]`, a write more than one past the end, `delete a[i]` for an existing element (JS leaves a
hole, it doesn't shift), and growing `length`; shrinking `length`, `push`/`pop`, appending at
`a[a.length]` and deleting past the end are fine.
**Regression tests (M7).** the `{b, a, 1, 0}` example → `0,1,b,a`; `"4294967295"` sorts as a
string, `"4294967294"` as an index; `"01"` and `"-1"` are strings; delete + re-add moves a key to
the end.

## D14. Compatibility contract
Every program run by ZQJS ends in exactly one of these outcomes:

| outcome | meaning | must agree with node? | catchable by JS `try`? |
|---|---|---|---|
| **ok** | accepted and run | yes: stdout and uncaught-error *name* identical | n/a |
| **SyntaxError** | invalid JavaScript | yes: node rejects it too | n/a (early error) |
| **Unsupported(feature)** | valid or uncertain JS outside the ZQJS subset | no claim | **no**: terminates the script |
| **LimitExceeded(limit)** | a configured resource limit was hit | no claim | **no**: terminates the script |

**Asymmetric default.** We report `SyntaxError` only when we are sure node rejects the input.
Anything uncertain is `Unsupported`. Unsupported claims nothing, so it can't be wrong.
**Why uncatchable.** If `Unsupported` were a catchable JS exception, a script could swallow it
and keep running with behaviour node never produces: unsupported behaviour masquerading as
JavaScript. The same holds for limits, which are also how a host sandboxes a script.
*Change from v2:* sparse-array writes are now `Unsupported`, not a catchable `RangeError`.
**Verification.** Syntax cases live in `tests/syntax/cases.jsonl`; `zig build check-goldens` *runs*
each case in node (some SyntaxErrors, like top-level `let undefined`, only appear when a
script starts) and asserts `ok` cases raise no SyntaxError and `syntax` cases do. From M3, `tests/diff/`
compares runtime output, and a diff test that ends in `Unsupported`/`LimitExceeded` *fails*.

## D15. Resource limits
One `Limits` struct, passed at runtime creation. A limit is added to the code in the milestone
that first enforces it; defaults are deliberately conservative.

| limit | default | enforced at | milestone |
|---|---|---|---|
| `max_source_bytes` | 16 MiB | parse entry / file read | M1 |
| `max_nesting_depth` | 512 | parser recursion + AST depth | M1 |
| `max_call_depth` | 1 000 | frame push (JS and native re-entry) | M6 |
| `max_stack_slots` | 1 Mi values | stack growth | M6 |
| `max_steps` | unlimited (CLI: 200 M, `--max-steps`) | every statement, every expression, every loop iteration | M3 |
| `max_heap_bytes` | 256 MiB | every heap allocation (from M8: after a collection first) | M3 |
| `max_string_length` | 2²⁸ code units | string creation / concat | M3 |
| `max_array_length` | 2²⁶ | element growth | M7 |
| `max_object_properties` | 2²⁰ | property insertion | M7 |
| `max_temp_roots` | 1 024 | `pushTemp` | M8 |

*CLI default:* the library leaves `max_steps` unlimited because an embedder must choose its own
budget, but the `zqjs` command defaults to 200 million steps (a few seconds), so an accidental
infinite loop ends with `LimitExceeded(steps)` instead of hanging; `--max-steps 0` removes it.
*Revised in M3:* the step budget charges every statement and expression evaluation as well as
every loop iteration, so long straight-line programs and deep expressions consume it too, not
only loops. Natives that loop internally (e.g. a future `join`) are bounded by the collection
limits.
*Shortcut accepted:* buffer growth through `heap.allocator()` cannot collect, so near the heap
limit it may fail although collectible garbage exists. `heap.new` collects early (`next_gc` is
capped at the limit), so this only bites in edge cases. Upgrade path: make buffer growth a safe
point, which turns every caller into a rooting site.

## D16. Tree-walker as oracle, sharing semantics with the VM *(planned, M3)*
All JS operations (`ToNumber`, `add`, `strictEquals`, property get/set, `typeof`) live in
`runtime/ops.zig` and are called by both the tree-walker and the VM. The oracle then checks what is
actually duplicated (compiler, bytecode, VM control flow) without implementing semantics
twice. Cost: each new syntax form needs a case in both back ends.

## D17. Exact toolchain pin: Zig 0.17.1
`build.zig` refuses any other compiler (`builtin.zig_version_string`); `minimum_zig_version` alone
only sets a floor. Locally: `brew pin zig`. CI (`.github/workflows/ci.yml`): `mlugg/setup-zig@v2`
with `version: 0.17.1`. Upgrades are deliberate commits.

## D18. Number literals are validated by our lexer, not by `std.fmt.parseFloat`
`parseFloat` accepts `1_0`, `inf` and `0x10`, none of which mean the same in JS. The lexer
accepts only `digits [. digits] [e[+-]digits]` and hands exactly that text to `parseFloat`
(which rounds correctly). Out-of-subset forms (`017`, `1_000`, `0x10`, `10n`) are
`Unsupported`. Malformed ones (`1e`, `3in`) are `SyntaxError`.

## D19. Memory-safety tooling
Verified on Zig 0.17.1 / macOS arm64: Zig has **no AddressSanitizer for Zig code**
(`-fsanitize-c` covers C only). `DebugAllocator` did **not** detect a small use-after-free read
or a many-pointer overflow. Guard Malloc (`/usr/lib/libgmalloc.dylib` + `c_allocator`) caught
the use-after-free at the exact line. `zig build test --fuzz` works.

| layer | catches | from |
|---|---|---|
| `std.testing.allocator` | leaks, double free | M1 |
| `checkAllAllocationFailures` | OOM error paths | M1 |
| Debug/ReleaseSafe checks | slice bounds, overflow, union tag, `unreachable` | M1 |
| `zig build test --fuzz` | crashes, hangs, invariant breaks | M1 (lexer/parser) |
| `-Dgc-stress` + poisoning + `verify` | missing roots | M8 |
| `-Dstack-stress` | pointers surviving stack moves | M6 |
| `-Dsystem-alloc` + Guard Malloc | real UAF/overflow (page granularity) | M8 |
| Valgrind (Linux CI) | UAF/uninitialised reads | M10 |

## D20. Name resolution goes into side tables, not into the AST
The parser numbers every variable use (`Ref.id`) and every declarator (`Declarator.binding`).
The resolver fills `Resolution.refs[id]` and `Resolution.bindings[binding]`, sized exactly from
the parser's counters. **Why:** the AST stays immutable (`*const`) after parsing, each pass owns
exactly what it writes, and a later pass can add its own table without touching the tree.
**Alternative:** a mutable `resolved` field in each identifier node. Simpler to read, but then
"parsed" and "resolved" are states of the same object.
**Algorithm:** see the header of `src/frontend/resolver.zig`. One `live` stack of visible bindings;
`scope_start` marks the current scope, saved on the Zig call stack while a nested scope is walked.
The *current* scope is `live[scope_start..]`, which is what the redeclaration check scans, so
shadowing an outer name is never mistaken for a redeclaration. Slot = index in `live`.

## D21. Assignment to an undeclared name is Unsupported
Sloppy JS silently creates a global (`y = 1`) or silently ignores the write (`undefined = 1`).
Until hosts can define globals (M9), ZQJS rejects such writes in the resolver
(`Unsupported(global_assignment)`). Reads of undeclared names stay legal (they reach the global
object at runtime: `undefined`, `NaN`, and later `print`).

## D22. `for (let …)`: one slot now, per-iteration copies in M6 *(done in M6: D36, D37)*
The spec creates a fresh copy of the loop-head bindings for every iteration
(CreatePerIterationEnvironment). Only closures can observe the difference. M3 and M4 use one
slot per head binding. **This is a simplification, not an architectural limit:** the head
declaration stays a distinct AST node (`for.init.declaration`) in its own resolver scope, so
M6 knows exactly which bindings to copy. With heap cells (D10), copying means "at the end of each
iteration, before the update, allocate a new cell holding the current value" for each *captured*
head binding. Required regression test listed in ROADMAP (M6).

## D23. Top-level `let`/`const` are script-local
In node, top-level lexical bindings of one script are visible to later scripts in the same realm.
ZQJS runs one script at a time, so top-level bindings are ordinary slots. Revisit with the
embedding API (M9) if hosts need several scripts to share bindings. The restricted-global rule
(`let undefined` at script level is a SyntaxError) is applied anyway, to match node.

## D24. TDZ is enforced at runtime, not by static analysis
Without functions (M2) every TDZ violation could be found statically, but closures (M6) make that
undecidable (`function f() { return x } f(); let x;`). M3 stores an internal `uninitialized` value
in a binding's slot on scope entry, checks it on every read and write, and overwrites it when the
declaration runs. A static "always initialised here" analysis may later remove checks as an
optimisation.

## D25. `**`: musl/Arm pow, accurate rather than V8-identical *(milestone P1)*
The spec makes `**` "implementation-approximated", so engines legitimately differ. We keep
three things apart:
1. **JS semantics**, exact: `ops.pow` handles the two cases where JS differs from C pow
   (`x ** NaN` is NaN even for x = 1; `(±1) ** ±Infinity` is NaN); every other special case
   (±0, ±Infinity, NaN, negative bases with integer / non-integer exponents) follows C99
   Annex F, which matches the spec.
2. **Accuracy** (distance from the true value): `src/runtime/pow.zig` ports musl's pow (Arm
   optimized-routines, 2018, MIT; see THIRD_PARTY_NOTICES.md): log to ~68 bits as `hi + lo`, then
   exp taking the extra bits as a tail, so only the final rounding matters; documented worst
   case 0.54 ulp. The tables in `pow_data.zig` are generated by `tools/gen_pow_data.js` from
   the hash-pinned musl sources.
3. **Agreement with node**: a compatibility metric, not an accuracy metric. Where V8 is the
   one that's off, agreeing would mean being wrong.

**Why not fdlibm's `e_pow.c`:** not available locally to read and verify; musl's code is
(bundled with Zig) and is more accurate. **Why not `std.math.pow`:** it ports Go's `math.Pow`
(frexp + repeated squaring).

**Measured** on the 7,942 finite cases of `tests/ops/pow_reference.jsonl` (true values from
Python's `decimal` at 60 digits, `tools/pow_reference.py`):

| implementation | correctly rounded | 1 ulp off | worse | worst |
|---|---|---|---|---|
| old `std.math.pow` | 31.68% | 1,203 | 4,223 | 1.9e10 ulp |
| node (V8) | 92.04% | 632 | 0 | 1 ulp |
| ZQJS `pow` | 99.89% | 9 | 0 | 1 ulp |

**Permanent tests** (`tests/ops_test.zig`), one per metric:
- accuracy: never more than 1 ulp from the true value, at least 7,933 correctly rounded;
- agreement: on 8,284 node cases, forced results bit-exact and everything else within 1 ulp.

**Portability, as measured** (`zig build pow-bits`, SHA-256 of all 8,284 result bit patterns):
identical (`b02251ea…`) on aarch64-macos (Debug, ReleaseSafe, ReleaseFast, `-Dcpu=apple_m1`)
and x86_64-macos under Rosetta 2 (`-Dcpu=baseline`, `x86_64_v2`, `haswell`). Haswell has FMA, so
an identical hash also shows the compiler does not contract `a*b + c` into fused operations
(Zig's default float mode is strict). We use musl's non-FMA code path so no result depends on
FMA hardware.
On real hardware, the same hash on GitHub's Linux x86_64, Linux arm64 and macOS arm64 runners
(Debug builds; first green run 2026-11-14 at commit df83aaa). CI repeats this check on every push.
**Not verified, so not claimed:** Windows, WebAssembly, 32-bit x86 (where x87 extended precision could cause
double rounding), or other compiler versions. Run `zig build pow-bits -Dtarget=…` there and
compare with the hash above before relying on bit-identity.

**Consequence:** where node is 1 ulp off, ZQJS prints a different last digit
(`0.5 ** -0.5`: ZQJS `1.4142135623730951`, the correctly rounded √2; node `1.414213562373095`).
That is documented in LANGUAGE.md as a known deviation, not a bug.

## D26. TDZ marker: slots are `?Value`
*(M6: VM slots are `Slot = union { value: ?Value, cell: *Cell }` and cells hold `?Value`; the
marker is still an optional, never a Value.)*
`null` means "not yet initialised". Zig's optional type makes it impossible for the marker to
reach JS code: every read must unwrap it, and the unwrap is where the ReferenceError is thrown.
**Alternative:** an internal `Value.uninitialized` tag, which every operation would have to remember
to reject.

## D27. Exceptions before objects exist
Until M7 there are no Error objects. An exception is `Exception { name: ErrorName, message }`
stored in `Runtime.exception`; the interpreter returns `error.Thrown`. **Ownership:** `name`
is a static enum; `message` is a heap string owned by `Runtime.heap`, valid until
`Runtime.deinit`, so it survives unwinding and the host can print it afterwards. If building
the message fails (heap limit, OOM), that failure is reported instead. In M7 the thrown
value becomes a real `Value`.

## D28. Heap accounting
Every runtime allocation is charged `header + payload + allocations × 16` *before* it happens,
with overflow-checked arithmetic (`std.math.add/mul`), and refused if it would pass
`max_heap_bytes`. The 16-byte per-allocation overhead stands in for allocator bookkeeping that
`std.mem.Allocator` doesn't expose; it stops floods of tiny or empty strings from slipping
under the limit. A refused or failed allocation leaves the counter unchanged (tested).
`max_string_length` is checked on the summed length, also overflow-safe.

## D29. Control flow is a value, not an error
`exec` returns `Completion = .normal | .break | .continue`; loops consume break/continue.
Zig errors are reserved for things that end the whole script (Thrown, LimitExceeded,
Unsupported, OutOfMemory, WriteFailed). The parser guarantees break/continue never escape a loop.

## D30. String literals allocate on every evaluation *(shortcut)*
The tree-walker creates a new heap string each time a string literal is evaluated. Correct,
but wasteful in loops; with no GC until M8 this memory isn't reclaimed during a run (the heap
limit still bounds it). The M4 constant pool creates each literal once; the tree-walker keeps
the shortcut because it stays untouched as the oracle.

## D31. Test layout
Small unit tests stay in `src/` next to the code they test (Zig's convention: they can test
private functions). Everything else lives in `tests/`, behind one root (`tests/all.zig`) and
the public `zqjs` module: whole-pipeline allocation-failure and fuzz tests, syntax cases,
node-generated golden tables (`tests/ops`) and whole-program differential tests (`tests/diff`).
`zig build test` builds exactly two test binaries.

## D32. Bytecode format *(M4)*
**Encoding.** A byte stream: 1-byte opcode, then little-endian u32 operands (slot, constant,
name, absolute jump target, argc). One table, `Op.info()` in `src/bytecode/bytecode.zig`, gives
every opcode's operands and stack effect; the compiler, verifier, disassembler and VM all read
it, so the format is defined once. Alternatives: fixed-width instruction structs (easier
patching, but two-operand instructions double the size of every instruction) and QuickJS-style
u16 operands (smaller, but one block with 70k `let`s or a call with 70k arguments overflows
them, which would need extra failure paths).
**Limits.** u32 operands do not make limits unnecessary. `Limits.max_code_bytes` (default
64 MiB, must stay below 4 GiB so u32 targets suffice) bounds one script's code;
`Limits.max_constants` (default 2^20) bounds its constant pool and, separately, its name table.
The compiler reports `LimitExceeded(code_bytes | constants)` with the statement's position; the
verifier checks both again. Slots and argc need no limit of their own: they are bounded by the
source size and, at run time, by the stack limit (D12).
**Calls.** `call argc` pops `[callee, args…]` and pushes the result. In M4/M5 only natives
exist: the callee is checked after the arguments are evaluated (TypeError if not callable,
as in the tree-walker), and the native gets the arguments as a slice of the operand stack,
valid during the call; natives cannot re-enter JS, so the stack cannot move. User functions
(M6) will define frames, `this` and returns, and may change this instruction.
**`const` writes** are known at compile time and compile to `assign_const` placed exactly where
the write happens (after the right-hand side for `=`, after the read, right-hand side and
operator for `op=`), which throws ReferenceError in the TDZ and TypeError otherwise. Order
tests: `tests/diff/err_const_*` and the `tdz_and_const` bytecode snapshot.
**No unreachable code.** The compiler tracks whether a statement can complete and skips code
after `break`/`continue`, after an `if` whose branches both leave, and after `for (;;)` without
`break`. This keeps listings honest and makes "verifier max_stack == compiler max_stack" an
exact, testable invariant.

## D33. The verifier is the M4 oracle *(M4)*
Nothing executes bytecode until M5, so M4's correctness check is a verifier that treats a Proto
as untrusted input (`src/bytecode/verify.zig`): sizes within limits; every byte part of a
well-formed instruction; slot, constant and name indices in range; constants are numbers or
strings; jump targets on instruction starts; over all reachable paths no stack underflow, no
depth above `max_stack`, equal depth where paths meet, an empty stack at `halt`; and no path
falls off the end. It is what lets the M5 VM push and pop without bounds checks (D12). Tests:
every diff program and accepted syntax case must verify with `Info.max_stack == max_stack` and
no unreachable instructions; a unit test per rule; fuzzing of the compiler (through the front
end) and of the verifier on arbitrary bytes. The verifier says nothing about *meaning*; that is
the differential tests' job once the VM runs the same bytecode (M5).

## D34. Compile-time string constants: ownership *(M4)*
String constants are heap `String`s created once by the compiler (deduplicated by content). The
heap owns them; the Proto references them and must not outlive the heap. Until M8 they live to
`Heap.deinit` like every heap object; with the GC, the Proto is what marks them (D9). If a
compilation fails (limit, OOM), `Heap.rollback(mark)` frees every object created since the
compile began, newest first, and returns their charge, so a failed compile leaves the heap
exactly as it found it (tested under allocation failure and limits). Rollback is sound because
nothing else allocates on that heap while the compiler runs and nothing outside the compiler
can reference those strings yet.

## D35. The VM and its `step()` contract *(M5)*
`src/vm/vm.zig`. State: `pc`, `sp` (indices), `slots: []?Value` (`null` = TDZ), `stack: []Value`
of exactly `max_stack` (no calls into JS yet, so it never grows; `max_stack` 0 is fine).
`run()` is `while (step() == .running)`, so `--trace` and the M11 debugger drive the same code.
**`step()`.** Executes exactly one instruction, charging one budget step *before* it.
`.running`: completed, `pc` is the next instruction. `.halted`: `halt` executed; later calls
return `.halted` and execute and charge nothing. An error is *precise*: `pc` still points at the
failing instruction and the stack and slots are exactly as before it (every instruction fails
before mutating, or mutates and then sets `pc`). Exception, limit and Unsupported details are on
the Runtime. The VM is then faulted: later calls return the same error and do nothing. Side
effects outside the VM (output already written by a native) are not undone.
**Calls.** `[callee, arg0 … argN-1]`, arguments in source order. The native *borrows* the slice
`stack[base+1 .. sp]`, valid only during the call (it cannot re-enter JS, so the stack cannot
move). The callable check comes after argument evaluation, as in the tree-walker. If the native
fails, nothing has been popped: the stack is a valid pre-call state. On success callee and
arguments are replaced by the result. M6 replaces the slice with `NativeCtx` (D12).
**Budget.** One step per executed instruction, charged before execution. `Runtime.step` checks
before incrementing, so the counter never exceeds `max_steps` and cannot overflow even when it
is `maxInt(u64)`. The unit is engine-defined, so thresholds differ between engines (LANGUAGE.md).
**Trust.** The pipeline always verifies before running (D33), in every build mode. The VM still
keeps cheap defensive checks (pc and instruction bounds, opcode validity, stack underflow and
overflow, slot, constant and name indices, jump targets) because the verifier protects against
malformed bytecode, not against bugs in the VM or the verifier. A failed check is a bug, so it
panics with the pc instead of producing a JavaScript-visible result. They stay until a benchmark
says otherwise.
**Messages.** The VM writes the same exception messages as the tree-walker. The tree-walker is
left untouched as the oracle, so the four message texts exist twice; the differential tests
compare messages, which catches any drift.
**Lesson (found by the differential tests on their first run).** `vm.top().* = .{ .number =
f(vm.peek(0)) }` is wrong in Zig: the union literal is built in place (result location), so the
slot's tag becomes `.number` *before* `f` reads the old value through `peek`, which then reads a
pointer's bits as a float. Every in-place store in the VM computes into a local first.
`tests/diff/unary_strings.js` is the regression test.

## D36. Functions in the VM: cells, two stacks, transactional calls *(M6)*
**Captured bindings are cells (decision A).** The resolver marks a binding `captured` when an
inner function refers to it, and gives each function a capture list: for each captured binding,
"my parent's slot i" or "my parent's capture j", so a binding two functions out is passed down
through the function in between. A captured binding's slot holds a heap `Cell { ?Value }`:
`new_cell` on scope entry (so *every execution* of a block gets fresh cells; a closure from an
earlier execution keeps its own), `box_local` for a captured parameter on function entry,
`*_cell` instructions to access it, and `*_capture` through the running closure from inner
functions. `make_closure` copies the cell pointers into the new closure, so all closures of a
binding share it, and it lives as long as any of them. Per-iteration `for (let …)` copies
(`fresh_cell`, before the first test and before each update) are emitted only for captured head
bindings; for the others the copy is unobservable. *Alternative:* open/closed upvalues (Lua,
clox, ~QuickJS): fewer allocations, but closing on every scope exit and `break`/`continue`,
per-iteration copies and stack relocation fix-ups are subtle code; cells cost one allocation
per captured binding per scope execution, measurable later.
**Frames and stacks (decision B).** `frames` (Proto, closure, return pc, where its locals and
operands start, where its callee sits), `locals: []Slot` (D26) and `stack: []Value`, all
addressed by index, all growable (`realloc`, geometric). Parameters occupy slots
`param_slot…` (1 in a named function expression, whose own name comes first). A callee's
operands start above its arguments; `return` cuts the stack back to the callee's position and
pushes the result there. *Alternative:* one stack with locals inline (no argument copy), but
TDZ would need a Value tag that could escape, or a `?Value` operand stack.
**Calls are transactional.** `enter` checks `max_call_depth` and `max_stack_slots`, reserves the
capacity of all three stacks (this may move them, which is invisible: everything is an index),
initialises the callee's locals *above* the live ones, and only then commits (pushes the frame,
advances `locals_len`, sets `pc = 0`). So a call that fails (a limit, out of memory) leaves the
caller exactly as it was: pc on the `call`, callee and arguments on its operand stack. `return`
restores the caller's pc, frame and operand depth. Both are tested directly (`tests/vm_test.zig`).
**`max_stack_slots`** bounds Σ(slot_count + max_stack) over all active frames, the script's
included: each frame's full reservation counts whether used or not, so neither deep recursion
of small frames nor shallow recursion of huge ones can get around it.
**`-Dstack-stress`** moves both stacks to fresh allocations on every call; the whole suite runs
with it in CI. Natives still cannot call back into JS, so the borrowed argument slice stays
valid; `NativeCtx.arg(i)` (D12) arrives with the first native that can.
**Lifetime.** Closures, cells and Protos: closures point at their Proto, which the Proto tree
owns; in `runSource` the tree outlives the run, and freeing a closure never touches its Proto.
Until M8 cells and closures live until `Heap.deinit` (bounded by the heap limit).
**Caught by the differential tests while building this:** a named function expression's
parameters were copied into slot 0, the function's own name (the VM assumed parameters start
at 0); the tree-walker, which doesn't use slots, disagreed. Fixed with `param_slot`.

## D37. Functions in the tree-walker: spec environments on its own stack *(M6)*
**Environment records (decision C).** The oracle deliberately does *not* use the resolver's
capture analysis or slots: every scope that declares something gets a heap `Env { parent,
scope, values: []?Value }` when entered (script, block, `for` head, call, a named function
expression's name), closures keep the record they were created in, and a binding is found by
walking the chain to its scope's record. Per-iteration bindings copy the `for` head's record,
as the spec does. So a mistake in capture analysis, cell handling or slot assignment in the VM
shows up as a disagreement, not as two engines agreeing on the same wrong answer. Cost: one
allocation per scope entry (garbage until M8), so long loops use far more heap here than on the
VM; limits are engine-specific (LANGUAGE.md).
**Native recursion.** The tree-walker recurses in Zig for every statement, expression and call,
across JS calls, so it counts that depth and stops at `max_interpreter_depth` (default 6000)
with `LimitExceeded(interpreter_depth)`. *(M8 P2: M7 and the shadow stack had grown `eval`'s
Debug frame, which holds the locals of every switch arm, to ~5-6 KB per level, 37 MB at the
limit on Linux x86_64, and the guard test failed in CI; the large arms are now separate
functions and the cost is back to ~2.3 KB per level, ~14 MB, on arm64 and x86_64.)* *Measured*
worst case at 6000 (plain recursion, and
recursion through a 200-deep nested expression): **~14.5 MB of stack in Debug** (2.4 KB per
level), ~4 MB in ReleaseSafe. That is more than an 8 MiB thread has (it only passed at first
because Zig gives executables a 16 MiB main stack), so the tree-walker runs on **its own thread
with a 64 MiB stack**; the caller waits, so the Runtime is never shared. The guard then holds
whatever stack the host thread has: a test runs worst-case recursion from a 256 KiB host thread
on both engines, and a unit test asserts the measured use stays under half of the 64 MiB, in
every build mode CI tests (Debug and ReleaseSafe).
**Debt.** A dedicated 64 MiB thread is acceptable for a reference implementation, but ~14.5 MB of
native stack in Debug is a lot, and its size depends on the compiler's frame layout. The proper
fix is an explicit interpreter stack (the walk keeps its own continuation records on the heap),
which makes memory use predictable and removes the thread. Listed in ROADMAP, Technical debt.

## D38. Objects on the heap, and what the GC will trace *(M7)*
**Representation.** `Object { proto, props, kind, builtin }`: `props` is an insertion-ordered
`AutoArrayHashMapUnmanaged(*atom, Property { value, enumerable })` (D13; no hidden classes, no
shapes, no inline caches); `kind` is ordinary or array (dense `ArrayList(Value)`); `builtin`
marks the built-in objects for lookup classification (D39). Atoms (D11) are interned Strings
that cache whether they are a canonical array index; the intern table hashes by content (FNV-1a
over code units, so ASCII source names and UTF-16 strings find the same atom). Keys are an
`.index` (0 … 2^32 − 2) or an atom. All semantics live in `runtime/object.zig`, called by both
engines (D16). Property tables, element lists and the atom table grow through
`Heap.allocator()`, a counting `std.mem.Allocator` that charges the same `max_heap_bytes` as
every other allocation (refusal → LimitExceeded via `Heap.failed`).
**Traceability (M7 acceptance).** Every reference edge is enumerated by `heap.forEachChild`, one
exhaustive switch over the object kinds, tested per kind; that function is M8's marking.

| from | edges |
|---|---|
| Object | prototype; each property's key (atom) and value; array elements |
| Closure (VM) | captured cells (the Proto is not a heap object yet: a root, below) |
| Closure (tree-walker) | its environment record |
| Env | parent record; binding values |
| Cell | its value |
| String | none |
| Value | strings, closures, objects (natives are static, never collected) |

**Roots** (M8 will collect from these): `Runtime.realm` (the eight built-in objects), the atom
table (weak in M8: D11), `Runtime.exception.message`, `Runtime.unsupported_name`, every Proto's
string constants (D9), the VM's operand stack, locals (values and cells) and frames (closures,
`this`), and the tree-walker's current environment, `this` and its Zig locals (the reason
D10's rooting discipline exists). Built-in objects are created on first use (`builtins.realm`),
so `Runtime.init` stays infallible.

## D39. Built-ins: implemented, known, nonexistent *(M7)*
A name can be three things, for globals and for properties of the built-in objects:
**implemented** (`runtime/builtins.zig`, with behaviour; the only ones that produce values),
**known** (node has it, ZQJS doesn't implement it: `Unsupported(builtin)`, naming it), or
**nonexistent** (a ReferenceError for a global, `undefined` for a property). The *known* names
come from node itself: `tools/gen_builtins.js` lists the own property names of the global object
and of each modelled built-in (Object/Array/String/Number/Boolean/Function prototypes, the
`Object` and `Array` constructors), taken from a fresh `vm` context (the environment the goldens
run in, so no `process`/`require`), into `src/runtime/builtin_names.zig`; `check-goldens`
verifies it against the node in use. Names alone never provide behaviour. A lookup is classified
where node would find the name: walking the prototype chain, at each built-in object that lacks
the key while node has it there, the lookup is Unsupported, even if a later object in the chain
has something by that name. `in` answers `true` for a known name (node has the property; no
value is needed). This also closes an M3 hole: `Math.PI` used to be a ReferenceError.
Implemented in M7: `Object.keys/create/getPrototypeOf`, `Array.isArray`,
`Object.prototype.toString/valueOf`, `Array.prototype.push/pop/join/toString`,
`String.prototype.charCodeAt`; calling `Object`/`Array` themselves is Unsupported.

## D40. Conversions use only the built-in methods; no native calls JS *(M7)*
ToPrimitive looks up `valueOf`/`toString` (string hint: the other way round) as the spec does,
but only *calls* them if they are the built-in natives (`isConversion`); a user function there,
or a different native, is `Unsupported(user_conversion)`. `Array.prototype.toString` likewise
looks up `join` and accepts only the built-in one. So no native ever calls back into JS in M7:
the VM never re-enters itself, natives' borrowed argument slices stay valid (D12), and
`NativeCtx` is still not needed. Joining arrays recurses in Zig, bounded by
`max_conversion_depth`; a cycle prints as empty, as in node. *Alternative:* re-entrant calls
from natives into JS now, which would make M7 much larger and change the VM's core invariants.

## D41. `this` *(M7)*
`this` is decided by the call expression, never by where a function is defined: a member call
`o.f(…)` / `o[k](…)` passes `o`, every other call passes no receiver; reading `this` without
one is `Unsupported(sloppy_this)` (sloppy JS gives the global object, which ZQJS doesn't have).
A primitive receiver of a user function is treated the same way (sloppy JS would box it into
a wrapper object); natives get the primitive as is (`'ab'.charCodeAt(0)`). `this` at script
level is Unsupported at parse time. So `const f = o.m; f()` and a function nested in a method
and called plainly both have no receiver; tests cover both on both engines. The receiver is
evaluated once (the callee is read from it, then the arguments are evaluated): the VM's
`call_method` takes `[receiver, callee, args…]`.

## D42. Generations: non-moving, promote on first survival *(M8.1; GC_DESIGN §15)*
**Two lists and two bits.**
- Objects live on two intrusive lists: `young` (every new object) and `old`.
- Two header bits, `old` and `remembered`, sit in existing padding, so objects don't grow.
- Nothing moves (D8; M9's C ABI relies on stable addresses). Promotion relinks an object and
  sets its bit.

**Minor collection.**
- It marks from the remembered set and the roots, but never traces into old objects, and
  sweeps only `young`.
- **Every survivor of any collection is promoted.** So after every collection the nursery,
  the remembered set and every card are empty (I-gen3), and no age counter is needed.
- **A minor collection never frees an atom:** an unmarked young atom is promoted instead,
  because the atom table still points at it. Promotion isn't marking, and strings have no
  children, so promoting keeps nothing else alive.

**Major collection.**
- It's M8's collector over both lists.
- It forgets the remembered set and cards first, rebuilds the atom table before any atom is
  freed, and sweeps the old list before the young one (survivors promoted onto `old` arrive
  unmarked).

**Nursery size.** `Limits.nursery_bytes`, default 256 KiB, chosen by measurement: a minor pause
is proportional to the nursery, while total GC time follows the garbage (and gets worse once
the nursery outgrows the cache).

*Alternatives:*
- an age counter (survive twice): no evidence that premature promotion costs enough;
- a copying nursery: moves objects, which the C ABI forbids.

## D43. Remembered set and cards *(M8.1; GC_DESIGN §15)*
**The remembered set.**
- The barrier in the store API (D8, I3) puts an old owner that stores a young reference
  (value, or new property key) on an intrusive list through `gray_next`, at most once (the
  `remembered` bit).
- It records owners, not edges: a minor collection scans the owner's current contents.
- It never allocates.

**Cards.** Arrays with capacity ≥ 512 and property tables with ≥ 512 entries keep side-table
bitmaps, one bit per 512 elements or entries (`cards`, `prop_cards`), so `Object` doesn't grow.
- A young store dirties the card of its index.
- `delete` dirties every card from the removed entry on, because entries shift down.
- A first bitmap for an already-remembered owner starts all dirty: the hole rule.
- Bitmaps grow before their buffers, so a failed allocation leaves both consistent.
- A minor collection scans only dirty cards (each scanned, then cleared).

**Checked.** The verifier checks every old-to-young edge independently of the bitmaps (I-gen2,
PC8). `zig build gc-mutants` proves that each of 8 deliberately broken pieces is caught.

*Measured:*
- one young store into a 1M-element array cost a 4.4 ms rescan without cards, against about
  0.012 ms with them;
- a 200k-entry dictionary's minor p95 went from 1.9 to 0.04 ms.

## D44. Adaptive major scheduling *(M8.1; GC_DESIGN §15 "Adaptive major scheduling", AS1–AS5)*
**The formula.** `next_major = live + min(max(f · live, 256 KiB), (limit − live)/c(f))`:
- `f ∈ {1, 2, 4}`, starting at 1;
- `c(1) = 2` (D8 as before), and `c(f > 1) = 4`, the quarter-room cap.

**The update rule.** After each major collection that went from `before` to `after` bytes:
- freed under 10% → `f = min(2f, 4)`;
- freed at least half → `f = 1`;
- anything in between → unchanged.

All of it is integer arithmetic on byte counts, so it's deterministic.

**What's proven** (GC_DESIGN §15):
- the limit is never exceeded (HL1);
- a burst of size `S ≤ (limit − B)/2` never fails, for every `f` (HL2), and the quarter cap
  makes the worst-case burst room for `f > 1` at least that of `f = 1`;
- a burst whose data truly doesn't fit fails as `LimitExceeded(heap_bytes)` under any
  schedule (HL3).

**Tests** cover the grid of bounds, the adaptation cycle, and a burst simulator on the heap API
that fails when the minor trigger ignores the half room. They also cover JS programs whose
bursts fit, and one that outgrows the limit.

*Measured:* game_1m runs 12 → 5 major collections over M8, and the frame loops of every game
workload run none.

*Not promised:* a burst between `(limit − B)/2` and `limit − R` may fail, depending on where it
lands. That comes from allocation never collecting (D7), and was true in M8 too.

## D45. The allocator: the embedder's choice; smp_allocator for the CLI and tools *(M8.1)*
`Heap.init` and `Runtime.init` take any `std.mem.Allocator`.

**Measured on macOS:** libc `free` was about 80% of a minor collection.
- On smp_allocator, minor p50 went from 0.061 to 0.011 ms, and game_100k's GC share from 18%
  to 5%.
- On Linux, without libc, the std default already was smp_allocator.

**The choice for our own binaries.**
- The CLI uses smp_allocator in release builds, and the std default (leak-checking) in safe
  builds.
- `zig build bench` and `gc-report` use smp_allocator and name it in every report header.
- `gc-report -- --allocator=libc` reproduces the older macOS numbers.
- Baselines from before M8.1 say which allocator they ran on. The `allocated` column also
  depends on it, because an allocator that can resize in place charges growth differently.

*Embedders* pick their own. M9's documentation will repeat the measurement.
