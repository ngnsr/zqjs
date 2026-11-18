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
| `max_native_stack_bytes` | 4 MiB | every native→JS crossing (D60) | D60 |

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
(which rounds correctly). Out-of-subset forms (`017`, `10n`) are `Unsupported`. Malformed ones
(`1e`, `3in`, `1__0`) are `SyntaxError`. M21.1 added `0x`/`0o`/`0b` and `_` separators: the
lexer still validates the shape; `frontend/number.zig` strips `_` before `parseFloat` and
converts radix integers itself (`parseFloat` truncates long hex mantissas), sharing that code
with `Number("0x…")` in `ops.zig`.

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
malformed bytecode, not against bugs in the VM or the verifier. A failed check is a bug. Until
M9.0 it panicked with the pc instead of producing a JavaScript-visible result; D49 revised that:
it returns `error.Internal` and poisons the runtime, because an embedder's process must not
crash on ZQJS's behalf.
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

## D46. Two modules: public zqjs and internal zqjs_internal *(M9.0)*
**Decision.** The repository provides two separate Zig modules:
- `zqjs` (`src/api.zig`): the only module an embedder's build can reach. It exposes only high-level opaque types (`Runtime`, `Program`, `Execution`), limits, error sets, and diagnostic structures.
- `zqjs_internal` (`src/root.zig`): all compiler, AST, parser, VM, heap, and GC internals. Used only by our own CLI debug tools, benchmarks, and internal integration tests.
**Why.** Zig cannot place one file in multiple modules with different visibility rules. Separating modules prevents accidental leaks of VM internals into host embedder code, ensuring internal refactors (heap, bytecode, GC) never break external embedders.
**Enforcement.** `tests/api_test.zig` and `examples/embed.zig` import only `zqjs`. A comptime snapshot test asserts the exact list of public declarations; adding an export requires explicit review.

## D47. Opaque types, strict ownership hierarchy, and the atomic guard *(M9.0)*
**Decision.** The public API exposes three opaque types: `Runtime`, `Program`, and `Execution`.
- `Runtime` owns its heap, realm, root list, and all programs/executions created under it. Nothing outlives its runtime; `Runtime.destroy` reclaims everything.
- `Program` uses internal reference counting (1 for the host handle, plus 1 for each active `Execution`). Calling `Program.destroy` invalidates the host handle immediately, while running executions continue cleanly. Bytecode and constant GC roots are freed when the last execution dies or the runtime is destroyed.
- `Execution` holds independent VM state (stacks, frames, pc, top-level bindings). `Execution.destroy` drops its roots and stacks immediately.
**Concurrency.** A runtime is strictly single-threaded at any moment. Every API call claims an atomic CAS entry guard on the runtime and releases it via `defer`. Overlapping calls (from concurrent threads or host output writer re-entrancy) panic with `"zqjs: Runtime entered while another call into it is running"`.
**Use after destroy.** A host bug, caught at every entry point in safe builds by a tag check that panics naming the type (`"zqjs: Program used after destroy"`…). `Program.destroy` also clears a `host` flag on the impl, so the case "destroyed while executions keep it alive" is caught deterministically, not only while the freed memory happens to stay poisoned. Best effort by design: freed memory may be reused, so a missed catch is possible; documented as such. The guard is on in every build mode; the tag checks compile out in ReleaseFast.

## D48. Cooperative executions, slices, and cumulative step limits *(M9.0)*
**Decision.** Executions are sliceable and cooperative:
- **Slice:** `resume(ex, steps)` bounds the maximum instructions executed in a single call. Running out of a slice returns `.suspended`, leaving VM state exact and intact for subsequent frames.
- **Cap:** `limits.max_steps` bounds the cumulative instructions an execution may execute over its lifetime across all resumes.
- **Exact limit rules:**
  - Instructions run only if `used < max_steps`.
  - An execution reaching the cap yields `.suspended` if the slice also ended; the subsequent instruction attempt fails with `LimitExceeded(steps)`.
  - A script completing at or before the cap finishes with `.finished`, never an error.
  - A faulted execution remains faulted; subsequent resumes return the cached error.

## D49. Internal errors as results instead of panics *(M9.0; D35 revised)*
**Decision.** Bytecode verification failures and defensive VM sanity checks return `error.Internal` and record an `internal` `Failure` rather than panicking.
**Why.** In an embedded context, a scripting engine bug must not crash the host process. An `Internal` error flags an invariant violation in ZQJS itself.
**Poisoning.** An internal error poisons the runtime: subsequent calls return `Internal`, and only `Runtime.destroy` is permitted, because the VM's internal invariants can no longer be trusted. The flag lives on the internal `Runtime` (`poisoned`), checked by the embedding API's every entry that runs code; `collectGarbage` and `memory` stay usable (they touch no VM state), and the destroy paths stay usable, since the host must be able to clean up. The first failed check's reason (a static string, or formatted into a fixed buffer for the verifier's report) is kept for the host's report and the CLI's `internal error: …` line; the `Failure` text itself stays the fixed `internal error` (E10).

## D50. Handles: generation-checked reusable slots with value tokens *(M9.1; E1 amended, revised after D1)*
**Decision.** A value crossing the boundary in either direction is referenced through a **handle** (`zqjs.Handle`): a value token `{ owner, slot, generation }` naming a reusable slot in the runtime's handle table, with zero per-token heap allocation.
- **Slot** (`Runtime`'s handle table): `{ value: Value, generation: u64, live: bool, next_free: u32 }`. The table is one GC root set (GC_DESIGN §4's reserved "Host handles" line): every slot with `live == true` is marked, so a value the host holds survives any collection, and releasing the handle makes its slot unrooted and reusable immediately.
- **Value token (`Handle`):** `{ owner: *Runtime, slot: u32, generation: u64 }`. Each owned handle occupies its own slot (`1` live handle = `1` live slot):
  - `dup` allocates an independent slot (reusing the free list when available) holding the same `Value`, returning a new `Handle` with the new slot's index and generation.
  - `release` validates the handle, marks its slot dead (`live = false`), increments the slot's 64-bit generation (`generation += 1`), and returns the slot to the free list. If a slot's generation reaches `maxInt(u64)`, the slot is permanently retired rather than pushed onto the free list, preventing generation wraparound.
  - Because `release` bumps the slot's generation immediately and `dup` uses a separate slot, releasing a handle deterministically invalidates that token (even after its slot is reused for a later handle, and even if the caller copied the `Handle` struct by value) without affecting any `dup`ed handle.
- **Validation:** Every handle access checks owner pointer equality (`handle.owner == rt`, panicking with `"zqjs: Handle from another Runtime"` on mismatch), slot bounds (`handle.slot < slots.items.len`), `slot.live`, and `handle.generation == slot.generation` (panicking with `"zqjs: Handle used after release"` if dead or mismatched).
- **`Runtime.destroy`:** the slot table and everything it references die with the runtime (E1: nothing outlives it). Using a handle after destruction is a host lifetime violation the plan does *not* claim to detect (the checking memory is freed) — stated explicitly, same class as a `*Program` after `Runtime.destroy`. Detection is promised only while the runtime is alive.
- **Bounded concurrent capacity and memory accounting:** `Limits.max_handles` caps the **maximum slot / concurrent live-handle capacity** (host-owned and engine-owned callback temporaries alike), not lifetime token creations. Recycled slots are reused across calls and frames without growing the table, so long-running 60 FPS hosts can execute millions of native calls in steady-state memory. Exceeding `max_handles` concurrently live slots (plus any retired wraparound slots) returns `LimitExceeded(handles)` with the runtime left usable (E6). `Runtime.memory()` reports `heap_bytes` (GC-managed JS heap), `handle_bytes` (actual allocated handle-table capacity), and `bytes` (`heap_bytes + handle_bytes`, total accounted runtime memory, D28).
- **Temporary argument handles and `NativeOut.result` ownership:** when JS calls a host native, the engine allocates ordinary handle slots for `this` and each argument, owned by the engine's native-call record (D53) and recycled at its teardown on every outcome. Three handle categories cross a callback boundary:
  1. **Borrowed temporary handles (`this`, `args[i]`):** owned by the `NativeRecord`; valid only during the call. Retaining one beyond the call requires `dup`; assigning `this` or `args[i]` directly to `out.result` is permitted (copied before teardown without double-release).
  2. **Transferred result handle (`out.result`):** assigning a `Handle` to `out.result` moves ownership of that handle to the engine, which copies its `Value` into the caller's operand slot and releases the handle's slot at teardown on every outcome. Freshly minted handles (`new*`, `call`) can be assigned directly without leaking.
  3. **Host-owned retained handles:** to return a handle `H` that the host already owns while keeping `H` valid after the callback, the callback must assign `out.result = try H.dup()`; passing `H` directly moves `H` to the engine and releases its slot at teardown (after which using `H` panics).
**Release-order invariant (review condition).** A temporary or result handle stays a GC root until its destination is safely written: the engine copies a result into the (rooted) destination first and releases the handle after; if the write can trigger an allocation (stack growth) or a collection, the slot remains live across it.

## D51. Model B re-entrancy: separate nested VM executions over a shared execution context *(M9.1; D35 revised, D48 extended)*
**Decision.** A host native may call back into JavaScript (R1) and stay GC-safe under stress (R2) by running every nested call on a fresh VM that shares the runtime's heap and realm, while the outer VM stays suspended mid-instruction (its stacks untouched, its roots still registered). `rt.call` and the native path share one implementation. Model A (nested native frames on one VM) is a future optimization, gated on a feasibility prototype measuring nested-VM cost; model C (never-moving stacks) stays deferred to M10.
**The shared execution context** (one per top-level entry: a `resume`, or a host `rt.call` at guard depth 0) owns:
1. the **cumulative budget** (`used`/`max_steps`, E4) — charged by every VM and native record in the chain via `rt.step()`; a nested call never installs a fresh budget;
2. the **logical call-depth counter** — VM frames and native records alike, one `max_call_depth` across the chain;
3. the **re-entry state** (the guard, D52);
4. the **active-VM root registrations** — every VM registers on creation and deregisters on teardown; a suspended VM stays registered for its whole suspension.
**Steps and the slice (D48 extended).** A `resume(steps)` slice is a promise about when the host regains control, not a hard stop: a synchronous native callback cannot suspend mid-callback (its C call stack is active), so a native chain may **overshoot the slice**; the host regains control when the chain completes and the VM next reaches a step boundary. The hard stop is the cumulative `max_steps`, checked by `rt.step()` at every instruction of every VM in the chain (the counter never exceeds it).
**Latched budget fault (review-frozen).** Budget exhaustion latches in the execution context: the first exhaustion latches `LimitExceeded`; subsequent nested execution cannot consume instructions; the native may finish its current callback but cannot clear or replace the latch; at the native boundary the outer execution faults with the latched `LimitExceeded` regardless of the native's return value.
**D35 (third revision).** A `.call` to a host native spans the steps of whatever runs inside it and is precise at its own boundary: on fault or throw, the caller VM's operand state is exactly as before the call (D36's transactional calls are untouched — model B puts no native frame in the VM).

## D52. The guard's entry kinds and the callback-scoped capability *(M9.1; E2 revised)*
**Decision.** The guard becomes a per-depth **entry-kind stack** plus owner thread id, in the execution context (D51):
- **`host` entry** — every pre-existing public entry point. Requires depth 0 and an unclaimed thread; claims the owner thread. At depth > 0 (same thread or not): panic, as in M9.0 — all M9.0 expected-panic tests stay green unchanged.
- **`engine` entry** — pushed only by internal sites (native dispatch and the engine-side implementations of the sanctioned re-entrant APIs) and only with the in-flight **native-call record** as proof. The record type is internal (never exported through `zqjs`), so host code cannot obtain, hold or forge one; teardown consumes it and pops the entry, so it cannot be reused after its callback ends. Cross-thread: panic, always.
**What a native may call (the sanctioned re-entrant API):** `rt.call`, handle operations (`new*`/`dup`/`release`/readers/`throwJs`), `rt.collectGarbage`, read-only `memory`. What it may not call: `compile`/`start`/`run` return **`error.Busy`** (the execution is unaffected; a host that wants to queue work can act on `Busy`); anything else needing a `host` entry (e.g. `resume` of the suspended outer execution, `defineGlobalFunction`, `Program.destroy`) panics — host-driven re-entry is rejected outright (no exception carved out). While poisoned, no callback starts and no token is minted (E7); destroy paths stay available.

## D53. Host natives: `defineGlobalFunction`, native-call records, and `error.HostError` *(M9.1; E5/E6 extended)*
**Decision.**
- **Registration.** `rt.defineGlobalFunction(name, native, ctx)` adds a host native to the realm (E3: realm changes persist across runs). Duplicate names — including built-in names — are `error.NameTaken` and leave the realm unchanged. `ctx` is **borrowed by the runtime until `Runtime.destroy`**: ZQJS never frees or dereferences it beyond passing it back; no destructor callback in M9.1.
- **Calls.** A `.call` reaching a host native pushes a *native-call record* on the execution context (D51): the temporary tokens (D50), the caller VM's result slot and `pc`, a depth charge. The record is the guard's engine capability (D52). The native receives `this`/`args` as tokens valid only during the call (D50).
- **Errors (each with its meaning; only Thrown is JavaScript-visible, E5):**
  - `Thrown` (+ `rt.throwJs(name, utf16_message)` first): a deliberate JS exception; returning it without a pending throw is a host bug (checked).
  - **`HostError`** (+ `out.host_message`, copied by the engine into a host-classified `Failure`): a host operation failed (a database lookup, a missing resource); faults the execution, does **not** poison the runtime — a proper error boundary, not a misleading `RangeError` throw. Returning it without a message is a host bug (checked). It joins the public error sets (`resume`/`run`/`call` can fault with it).
  - `LimitExceeded`/`Unsupported`/`OutOfMemory`: as in M9.0 — the execution faults, the runtime stays usable (E6). `Internal`: a host bug; the poison belt catches it (E7/D49). (`WriteFailed` is absent: natives produce no output.)
- **Precision.** A native call that throws or faults leaves the caller VM's operand state exactly as before the call (D35); the record's tokens are released on every outcome.

## D54. Language conversions unchanged; uniform string handles *(M9.1)*
**Decision.** D40 stands: a `valueOf`/`toString` that is not the built-in native remains `Unsupported(user_conversion)`. Language semantics do not change in the same milestone that adds embedding; the re-entrancy machinery makes the change *cheap*, which is why it is recorded here as deliberate, not forgotten.
**String handles.** Strings get handles like every other value (uniform model): a string token exists to pass the string back into JS safely and to survive collections. `Handle.string(buf)` copies the UTF-16 units out **without allocating** (no `OutOfMemory`), returns the string's **full length** (a too-small `buf` truncates visibly, `len > buf.len`), and signals a wrong-kind handle separately (`null`). Numbers and booleans read the same way (`?f64`/`?bool`, null = wrong kind); leaf reads never allocate (Q10).

## D55. `try…finally`: a completion record in hidden slots, not subroutines *(M27; approved 2026-11-18 with the clarifications at the end)*
**Decision (VM).** A `finally` block is compiled **once**, at one join point, and its exits
are routed through two hidden local slots of the enclosing frame (allocated like for-of's
`iter_slot`): `pending_kind` (a number) and `pending_value` (a Value). Every way out of the
protected region (`try` block, and `catch` block when present) is lowered to "set the record,
jump to the finally":
- falling off the end: `kind = normal`;
- `return e` (in the region, not inside a nested function): evaluate `e`, `value = e`,
  `kind = return`;
- `break`/`continue` whose target loop or switch is *outside* the region: `kind = jump_i`, one
  `i` per distinct target (the compiler numbers them per `finally`);
- a JS exception: a catch-all entry in `Proto.handlers` covering the whole region (the `catch`
  block included) with `has_binding = true`; its handler code stores the caught value,
  `kind = throw`.

After the `finally` body, a dispatch chain (`get_local kind; push_const k; strict_eq;
jump_if_false next; …`) re-performs the pending completion **in the enclosing context**: the
compiler emits an ordinary `return pending_value`, `break`/`continue` to target `i`, or `throw
pending_value` there. So nested `finally` blocks compose by plain recursion: a `return` that
crosses three `finally` blocks becomes "record, jump" three times. If the `finally` body
completes abruptly itself (its own `return`, `break`, `throw`), that completion simply wins and
the record is dropped, as in the spec. `try {…} catch {…} finally {…}` is `try { try {…} catch
{…} } finally {…}`. Both slots are cleared (`clear_local`) after dispatch so a value isn't
kept alive past the statement.

**No new control-flow instructions, no verifier changes.** Every jump is static, so D33's
verifier and `max_stack` accounting work unchanged; the handler entry reuses M11.2's format.
Only `throw` of a stored value is needed, which `throw` already does. Code size is linear in
the source (the body is emitted once; each crossing adds a few instructions).

*Alternatives considered.* (1) **Inline duplication** of the `finally` body at every exit
(simple, but exponential in nesting depth: a `finally` containing a `try…finally` is copied at
each outer exit). (2) **QuickJS-style `gosub`/`ret`** with a return pc on the operand stack:
linear code, but `ret` is a computed jump, so the verifier would have to model subroutines
(reachability and equal stack depth at every `gosub` site), and a pc in the operand stack is a
non-Value the GC and `-Dstack-stress` would have to know about. The completion record needs
neither, and it keeps the pending state in **frame slots**, which matters for D56: a frame
suspended by `await` inside a `try` with a pending `return` keeps that state with no extra
work.

**Decision (tree-walker).** `execTry` runs the region; it captures either a `Completion`
(D29: normal, break, continue, return — the return value is already in the interpreter's
return slot) or `error.Thrown`, in which case it takes the value with `catchValue()` and roots
it on the shadow stack. It runs the `finally` block; an abrupt completion or error from the
`finally` wins; otherwise it re-performs the saved one (`throwValue(saved)` for an exception,
restoring the saved return value for `return`).

**Uncatchable faults skip `finally`.** `LimitExceeded`, `OutOfMemory`, `Unsupported` and
`Internal` are not JS exceptions (M11.2); they already skip `catch` and unwind to the host, and
they skip `finally` too: the execution is over, and running user code after a budget or memory
fault would defeat the limit. Same rule as V8's termination. Documented in LANGUAGE.md.

**Tests.** Node-differential tests for every exit kind crossing 1–3 nested `finally` blocks
(return value overridden by `finally`'s return, `break` out of `finally`, exceptions replaced
by exceptions thrown in `finally`, `continue` in loops, `switch`); closures created in the
region; per-iteration bindings; a timing-ratio test that deep nesting compiles linearly; an
allocation-failure test; and a check that `LimitExceeded` inside `try` does *not* run
`finally`.

**Clarifications (review, 2026-11-18).**
1. **The record is cleared on every way out of the `finally` body**, not only after dispatch.
   A `return`, `break` or `continue` that leaves the body emits `clear_local` for both slots
   before its jump or return, because the compiler knows it is inside that body. An exception
   leaving the body goes through a second catch-all handler covering exactly the body; its code
   clears both slots and rethrows. So a frame that keeps running after an abrupt `finally` never
   retains `pending_value`. Leaving the frame frees its slots anyway.
2. **Handler order and ranges.** `Proto.handlers` is innermost-first and `unwind` takes the
   first range that matches (M11.2). With `try {A} catch (e) {B} finally {C}`:
   - the inner `catch` handler covers exactly `A` and is appended first, because the inner
     statement is compiled first;
   - the `finally` handler covers `A` and `B` and is appended after it, so an exception in `A`
     reaches the `catch` first and the `finally` handler only sees what escapes `A`+`B`;
   - neither range covers the handler code, `C`, or the dispatch chain, so an exception thrown
     by `C` or by the dispatch's rethrow never re-enters its own `finally`.
   The verifier already checks that ranges and `catch_pc` are in bounds. M27 adds a compiler
   assertion that a `finally` handler's range never contains its own `catch_pc`.
3. **Which jumps cross a `finally`.** The compiler keeps one stack of control contexts: loops,
   `switch` blocks and `finally` regions, in nesting order. A `break`/`continue` resolves its
   target, and the `finally` regions pushed *after* that target are the ones it crosses. If
   there are none, it is a plain jump. Otherwise it records `jump_i` in the *innermost* crossed
   region and jumps to its `finally`. That region's dispatch re-performs the same `break` in its
   own context, where the same rule finds the next crossed region, if any. A `return` crosses
   every `finally` region of the current function. A `break` whose target loop is inside the
   protected region crosses nothing. Tests: `while (true) { try { break; } finally { … } }`, a
   labelled-free nesting of loop / switch / three `finally` levels with `break`, `continue` and
   `return` from the innermost, and a `continue` that crosses one `finally` but not another.

## D56. `async`/`await` on the VM: one coroutine VM per async call *(M28; architecture accepted 2026-11-18, invariants added below; tree-walker decision open)*
**What a suspension is.** `await` is only legal directly in an async function's own body (not
in a nested non-async function, not at script top level: there, `await` stays
`Unsupported(syntax)`, a restriction like D21's, since scripts have no top-level await and
using `await` as an identifier is sloppy-only). So at an `await`, the suspending code is
always **frame 0 of the async call**, at an instruction boundary, with no native call in
flight and no nested VM above it. Nothing below that frame has to be preserved.

**Decision: each async call runs on its own VM (a coroutine).** Calling an async closure,
from any VM or from a native (`callCallable`), does not push a frame on the caller's VM.
Instead the engine:
1. creates the result promise `P` and a heap object `Coroutine { vm: *Vm, promise: *Object,
   state: running | suspended | done }`, whose VM runs the closure as frame 0, exactly as D51's
   nested VMs do (`nested = true`, sharing the current execution context: one budget, one
   call-depth counter, one guard);
2. runs it synchronously until it finishes or reaches `await`;
3. returns `P` to the caller, which never sees the coroutine.

To the caller this behaves like a native call (D35 precision at the call boundary). D51's
machinery is reused unchanged: the coroutine VM registers as an active VM root while it runs,
and deregisters when it suspends or finishes.

**`await v` (new opcode `await`).** It pops `v` and stops the coroutine VM's run loop with a
new state, `.awaiting`. The driver (Zig code, not the VM) then:
- converts `v` with the existing `Promise.resolve` logic (a native promise with the realm's
  prototype is used as is; anything else becomes a new fulfilled promise; M18's native-only
  adoption rule is unchanged, so foreign thenables are not called);
- attaches **one internal reaction** of a new kind, `.await_resume { coroutine }`, to that
  promise directly (spec PerformPromiseThen with no result capability: no throwaway child
  promise);
- marks the coroutine `suspended` and returns.

When the reaction runs (a microtask, M18's queue), the driver resumes the coroutine VM:
- **fulfilled:** push the value and continue at the instruction after `await`;
- **rejected:** set the thrown value and enter D55's/M11.2's unwind at the `await`'s pc, so
  `try`/`catch`/`finally` around an `await` work unchanged.

**Completion.** A `return v` in frame 0 ends the VM (D51's `nested_result`); the driver
resolves `P` with `v` (M18's resolve: adopting a native promise, self-resolution TypeError). An
uncaught JS exception rejects `P` with the value (`catchValue()`, so engine errors become the
M25 error objects). An uncatchable fault (`LimitExceeded`, `OutOfMemory`, `Internal`) does
**not** settle `P`: it propagates to the host like any fault (M18's rule: the active microtask
is consumed, the queue is preserved), the coroutine is marked `done`, and `P` stays pending.

**Ordering.** Must match Node exactly, checked by Node-differential tests: `await` of a native
promise or a plain value takes one microtask tick; an async function returning a native promise
settles `P` through M18's two-step adoption. The suspension/resumption points are the only
observable places; nothing else depends on the coroutine representation.

**GC.**
- `Coroutine` is a new heap object kind, traced by `forEachChild`: its `promise`, and while
  `suspended` its VM's live state with the same code as `Vm.markRoots` (operand stack to `sp`,
  locals to `locals_len`, frames' closures and `this`). While `running`, the VM is an ordinary
  registered root, so the object traces nothing extra.
- An `.await_resume` reaction holds its coroutine, so a coroutine is alive exactly while some
  reachable promise can resume it. A coroutine awaiting a promise nobody can settle becomes
  garbage with it, and `release` frees its VM (no leak, and no host action needed).
- **Generational barrier (D43).** A running VM writes its stacks without barriers. When a
  coroutine *suspends*, its stacks may hold young values while the `Coroutine` object is old,
  so the driver calls `remember` on the object at every suspension. One call per `await`, not
  per store.
- `-Dgc-stress` and `-Dstack-stress` apply inside coroutines like any VM; a test awaits in a
  loop with collections forced between resumptions.

**Memory and limits.** A suspended coroutine's VM is heap-owned memory: its charge is
`@sizeOf(Coroutine) + @sizeOf(Vm) +` the capacity of its three stacks, recomputed at each
suspension. The driver first shrinks the stacks to the frame-0 high-water mark (`max_stack`,
`slot_count`), so ten thousand pending small async calls cost kilobytes each, not the growth
headroom, and counts the result against `max_heap_bytes`. Running coroutines count
against `max_stack_slots` and `max_call_depth` through the shared execution context, like any
nested VM. The heap limit therefore bounds the number of pending async calls; no separate
limit is introduced.

*Alternatives considered.* (1) **Copy frame 0 out to the heap at `await` and back in at
resume**, running async calls on the caller's VM: no VM allocation per call, but the copy has
to rebuild `locals_base`/`stack_base`/`result_index` on whatever VM resumes it and interacts
with D36's transactional `enter` and `-Dstack-stress` moves. It is a later optimisation behind
the same `Coroutine` interface, if profiling shows VM creation matters. (2) **CPS-transforming
async bodies into state machines in the compiler** (Regenerator style): no runtime support,
but every local live across an `await` must be hoisted, which conflicts with the resolver's
slot and cell decisions (D20, D36), and `try`/`finally` across `await` turns into a large
state-machine rewrite.

**Tree-walker: VM-only for now (decision needed).** The tree-walker recurses in Zig (D37), so
suspending in the middle of an async body would need a separate native stack per pending call
(a thread or hand-written context switching) or the explicit interpreter stack that D37 lists
as debt. Proposed: in M28 the tree-walker reports `Unsupported(async)` for async functions;
async diff tests run on the VM and are checked against Node `.out` files, which is the stronger
oracle anyway. Async support in the tree-walker comes with paying off D37's debt (continuation
records on the heap), which also removes its 64 MiB thread. *Alternative:* do D37 first and
keep both engines in lockstep; this delays async by a milestone.

**Syntax in M28:** `async function` declarations and expressions, async arrows (`async x =>`,
`async (a, b) =>`, `async () => {}`), async methods in object literals, `await` as a unary
operator (precedence of `typeof`; `await` inside default parameters is a SyntaxError, as in
JS). Deferred: async generators, `for await`, top-level `await`, unhandled-rejection tracking.

**Invariants (review, 2026-11-18; required before M28 starts).**
1. **Rooting during construction and the synchronous run.** The driver holds `P` and the
   `Coroutine` in a stack-local `ValueRoots`/object-root set (M16/M19 style) from the moment
   each is allocated until the call returns. Order: allocate `P` → root it; allocate the
   `Coroutine` with `state = starting, vm = null` → root it; create the VM (owned by the
   coroutine from this point; an `errdefer` frees it and leaves `state = done, vm = null` if
   creation fails); register the VM as an active root; run. Registering the `await` reaction
   and suspending happen while the driver's roots are still live, so no allocation on those
   paths (reaction list growth, the resolved promise for a non-promise `v`, the accounting
   step) can collect the coroutine or `P`.
2. **Coroutines in microtask jobs and reactions.** `Microtask` and `PromiseReaction` gain a
   field `coroutine: ?*Coroutine`, never a raw pointer the GC can't see:
   - `PromiseState.reactions` entries are traced by the promise's `forEachChild`;
   - queued jobs are traced by `Runtime.markRoots` (the loop over `microtasks[head..]`);
   - the job being run is traced through a new `Runtime.active_job: ?Microtask`, set before
     the job runs and cleared after it, which `markRoots` also marks (`drainMicrotasks`'s
     `ValueRoots` only holds Values).
3. **Who owns the VM, by state.** One owner at a time, and `vm` is null exactly when no VM
   exists:

   | state | VM memory owned by | traced by | VM registered as active root |
   |---|---|---|---|
   | `starting` | the `Coroutine` | the driver's roots | no |
   | `running` | the `Coroutine` | the registration | yes |
   | `suspended` | the `Coroutine` | `forEachChild` | no |
   | `done` | nobody: `vm.deinit`, `vm = null`, charge released | — | no |

   `release` (sweep) frees the VM only if `vm != null`, so a coroutine that finished and is
   later collected is not freed twice. A coroutine is never collected while `starting` or
   `running`: it is held by the driver's roots or by `active_job`.
4. **Exact accounting of a suspended VM.** Its charge is `@sizeOf(Coroutine) + @sizeOf(Vm)`
   plus the capacity in bytes of every allocation the VM owns: `frames` (Frame), `locals`
   (Slot), `stack` (Value), and any backing array added later (the rule: a `Vm` field that owns
   memory must be listed in `Vm.ownedBytes()`, and a test compares it with a counting
   allocator). At suspension the driver shrinks each array to the frame-0 high-water mark. A
   shrink that fails keeps the old buffer, so shrinking can't fail. It then charges the
   difference from the previous charge through the heap's normal accounting, *before* setting
   `state = suspended`. If that charge exceeds `max_heap_bytes`, it is an ordinary
   `LimitExceeded(heap_bytes)`: the coroutine goes to `done` (VM freed, charge released), `P`
   stays pending, the fault propagates (M18's rule). The charge is released at `done` and at
   sweep.
5. **How a rejection enters exception dispatch.** `await` is precise (D35): when it suspends,
   `pc` stays **on the `await` instruction** and the operand stack is as it was after popping
   `v`. On resume:
   - fulfilled: push the value, advance `pc` past `await`;
   - rejected: set the thrown value (`throwValue`) and call the VM's `unwind` with the frame
     cache's pc on the `await`, exactly as if `await` itself had thrown. The `await` lies
     inside every `try` range around it, so the normal M11.2/D55 handler search applies. An
     uncaught rejection rejects `P`.
   Required tests, among others:
   `async function f() { try { await Promise.reject("bad"); } catch (e) { return e; } }`, and
   `async function f() { try { return await Promise.resolve(1); } finally { cleanup(); } }`
   (D55 × D56: the pending `return` record survives a suspension inside `finally`'s region).

**Clarification (M28b review, 2026-11-18).** A suspended coroutine's trace marks the VM's live
state exactly as `Vm.markRoots` does *except* the Proto's constants: those belong to the program
(`protoRoots`) or the script VM running it, and a coroutine can outlive a destroyed `Program`, so
its trace must never read the Proto. Resuming such a coroutine is the same host bug as calling a
closure of a destroyed program (EMBEDDING.md); merely collecting is safe.

## D57. Host-side promises *(M29; approved and implemented 2026-11-18)*
For a game host, the point of `async` is `await host.waitFrames(3)` or `await host.load(…)`:
JS awaits a promise that the **host** settles later, from its own loop. So the embedding API
gains, in Zig and C:
- `newPromise() → PromiseCapability { promise, resolve, reject }` (`zqjs_new_promise` in C;
  three owned handles; `resolve`/`reject` are M18 capabilities, callable through the existing
  `call`; partial mint failures roll back already-minted handles);
- `promiseState(handle) → ?PromiseState { pending | fulfilled(Handle) | rejected(Handle) }`
  (`zqjs_handle_promise_state` in C; `null` / `ZQJS_ERR_TYPE` on non-promise; never allocates
  or mints when pending);
- microtasks keep draining at the end of every outermost entry (M18), so a host `call` of
  `resolve` runs every coroutine it wakes before returning, under the same step and heap
  limits (D48, D51). A fault there is reported by that `call`, and later checkpoints continue
  the queue.
EMBEDDING.md must state explicitly:
- calls into a runtime must be serialised (E2, D52: one thread at a time, no re-entry outside a
  callback);
- the host settles promises only through ordinary API calls (`call` on a capability);
- settling drains microtasks at the outermost API checkpoint, before that call returns;
- step, heap and call-depth limits apply to the coroutines a settlement resumes;
- a fault during that checkpoint is reported by the host call that triggered it;
- an uncatchable fault can leave the affected promises pending, as in M18.

C API version: `ZQJS_ABI_VERSION` 1.2.0 (additive). Tests: a C host that runs a 60-frame loop
where scripts `await` frame timers, with leaks and handle counts checked after teardown.

## D58. Milestone order for D55–D57 *(revised by D59: M28 splits into M28a, the tree-walker rewrite, and M28b, async on both engines)*
M27 `try…finally` (both engines), M28 `async`/`await` (VM; tree-walker per D56's decision),
M29 host promises. M27 is independent and can start immediately; M28 depends on M27 (an
`await` inside `finally` must keep the pending record) and on D56's review; M29 depends on M28.
`class` waits for functions as objects (`.prototype`, `new` on user functions, `this` binding
in constructors), which gets its own design entry after M29.

## D59. The tree-walker on an explicit work stack *(M28a; approved 2026-11-18; replaces D37's "Native recursion" and pays its debt)*
**Why now.** D37 made every JS construct a Zig call, so the tree-walker needs a dedicated 64 MiB
thread (~14.5 MB of native stack in Debug at the depth limit), and it can't suspend in the
middle of an evaluation. D56 needs suspension for `await`; generators and the M11 debugger
stepping the oracle would need it too. D56's "VM-only" fallback would make `async` the first
feature the oracle can't check. Decision (2026-11-18): rewrite the tree-walker first, so both
engines implement M28's `async`.

**What stays (the oracle stays independent of the VM, D16/D37).** It still evaluates the AST
directly, still keeps spec environment records (`heap.Env`) and per-iteration copies, and still
ignores the resolver's capture analysis. Exception messages and the M25 error objects are
unchanged, and the shared `ops.zig`/`object.zig`/`builtins.zig` semantics too. The rewrite
changes *how* the walk is driven, not what it computes.

**Decision: a machine with two explicit stacks.**
- `tasks: ArrayList(Task)`: each `Task` is a tagged union naming an AST node plus the small
  state needed to continue it, for example `eval { expr }`, `binary_rhs { expr }` (the lhs
  value is already on `values`), `call_args { expr, next }`, `block { stmts, next }`,
  `loop_test { stmt }`, `scope_exit { saved_env }`, `call_return { saved_env, saved_this,
  call_marker }`, `try_region`/`finally_dispatch` (D55's semantics), `barrier`.
- `values: ArrayList(Value)`: intermediate results, like the VM's operand stack.

The run loop pops a task, does a bounded amount of work, and pushes follow-up tasks. A JS→JS
call pushes a `call_return` task and the body's tasks. **No JS construct nests a Zig call**, so
native stack use is constant per JS nesting level.

**Abrupt completions.** D29's `Completion` becomes an *unwind*: `break`/`continue` pop tasks to
the matching loop or `switch` task, `return` to the nearest `call_return`, and `throw` to the
nearest `try_region` (catch). D55's `finally` keeps its semantics: a `finally` task on the way
holds the pending completion in its own fields (rooted, see below), runs the `finally` body,
then re-performs the completion or lets the body's own abrupt completion win. Uncatchable
faults (`LimitExceeded`, `OutOfMemory`, `Unsupported`, `Internal`) are still Zig errors: they
abandon the machine's stacks entirely, as today.

**Natives that call JS (M16) and host calls (D51).** `callFromBuiltin` pushes a `barrier` task
and the call's tasks onto the **same** machine, then runs a nested loop until the barrier is
popped. Unwinding never crosses a barrier: a `throw` that reaches one returns `error.Thrown` to
the native, a `return` at the barrier is the call's result. Native → JS → native chains nest
one Zig frame of the run loop per native crossing, which is the same shape as the VM's model B
(D51) and bounded by `max_call_depth`.

**Limits and step counts stay identical.** `rt.step()` is charged exactly where the recursive
interpreter charges it: once per statement and per expression evaluation it starts. So step
counts are unchanged, and every existing step-limit test passes unchanged. `depth` (for
`max_interpreter_depth`) counts the same nesting the recursion counted: it goes up when an
`eval`/`exec`/`call` task starts and down when its continuation finishes. `interpreter_depth`
faults happen at the same programs as before (`tests/interpreter_test.zig:255` unchanged).
Since depth no longer costs native stack, the default could rise later; that's a separate,
documented change.

**GC.** The machine is an `EngineRoots` root set: every Value on `values`, every Value, Env or
object held in a `Task`, the current `env`, `this` and the pending completion values. The
shadow stack (`hold`/`release`, D10) goes away for the walk itself, because nothing lives in
Zig locals across a safepoint any more. Safepoints stay at task boundaries, exactly where
`safepoint()` runs now.

**The thread goes away.** `runOnOwnStack` and `stack_bytes` are deleted; the tree-walker runs
on the caller's thread. Existing test, kept: worst-case recursion from a 256 KiB host thread on
both engines. New test: native stack use measured at depth 10 and at depth
`max_interpreter_depth` differs by less than a fixed bound (a few KiB, the nested-loop frame).
The D37 stack-measurement test is replaced by this one.

**Suspension (what M28b uses).** An async call runs on its own `Machine` (mirroring D56's
coroutine VM): the coroutine heap object owns it, `await` returns from the run loop with
`.awaiting`, and resume pushes the value or starts an unwind at the `await`'s task. D56's five
invariants apply word for word, with "VM" read as "machine" (`Machine.ownedBytes()` covers
`tasks` and `values`).

**Performance budget.** The tree-walker is the oracle, not the shipped engine, so it may be
slower, but not by more than 1.5x on `bench/` (closures, fib, loop, objects, scopes, strings),
measured against the recursive version before it is deleted. More than that blocks the merge
until profiled.

**How it is built (M28a).** The new interpreter is written in a new file,
`src/interp/machine.zig`, while `treewalk.zig` stays as the reference. `Engine.treewalk`
switches to it only when **the entire existing suite passes unchanged** on it: every diff,
syntax, GC, stress and API test, the same step counts and the same limit faults. Then
`treewalk.zig` is deleted in the same milestone, so there is never a second oracle to keep in
sync. D37's "Native recursion" paragraph and ROADMAP's technical-debt row are closed by this
entry.

*Alternatives considered.* (1) **VM-only `async`** (D56's original fallback): fastest, but the
oracle stops covering the newest features exactly where bugs are most likely. (2) **A native
stack per pending async call** (threads or context switching): no general rewrite, but
platform-specific, heavy per call, and it keeps the 64 MiB recursion. (3) **CPS-converting the
recursive interpreter with Zig closures:** Zig has no closures, so it ends up as this task
union written less directly.

**M-order (D58 revised):** M28a explicit-stack tree-walker → M28b `async`/`await` on both
engines (D56) → M29 host promises (D57).

## D60. Bounding native stack across native→JS crossings *(approved and implemented 2026-11-18)*
**Problem.** D59 made JS→JS calls cost no native stack, but every native→JS crossing still
nests one Zig run loop: a built-in calling a closure (`rt.callCallable` → `Vm.callFromBuiltin`
/ `Machine.callFromBuiltin`, D51/D59), a host native calling `rt.call` (D52), and from M28b the
start of an async call's coroutine (D56). The only bound is `max_call_depth` (10 000), which
counts JS frames and crossings alike, so it allows thousands of crossings. With default limits
`function f(n) { return [n].map(x => f(x + 1)); } f(0);` overflows the 8 MiB main thread on
both engines (segfault; in Debug the overflow handler sometimes hangs at 0% CPU instead of
exiting, seen with `forEach` on the VM). Plain `async` recursion will do the same in M28b.

**Measured** (native stack per crossing: the distance between successive `callFromBuiltin`
frames over 200 crossings, `@frameAddress`, Apple M-series, 2026-11-18):

| engine | Debug | ReleaseSafe | ReleaseFast |
|---|---|---|---|
| VM | 49–52 KB | 3.9 KB | 3.6–4.0 KB |
| tree-walker (machine) | 70–72 KB | 24 KB | 25 KB |

Stable across `map`, `forEach`, `sort` comparators and callbacks with more locals (within
±3 KB). Almost all of it is the engine's own loop plus the built-in's frame (Debug VM: 47.5 of
49.3 KB; `callCallable` → `callFromBuiltin` is 1.4–1.8 KB). So the cost per crossing varies
**14×** with the build mode and **7×** between engines, and the stack available varies with the
host's thread (8 MiB main thread, 512 KiB macOS pthread default, 1 MiB Windows, 16 MiB
`std.Thread` default). An 8 MiB stack holds ~110 crossings in Debug on the tree-walker.
Async coroutine starts weren't measured separately; `async function f(n) { return f(n + 1); }`
overflowed the same way before this entry.

**Decision: a byte budget, checked against the real stack pointer.**
- New limit `max_native_stack_bytes`, default **4 MiB**, and `Limit.native_stack`.
- Every depth-0 entry (the API guard's claim, and `runSource` for the CLI) records
  `rt.stack_base = @frameAddress()`.
- One helper, `rt.checkNativeStack()`, runs at every crossing before it nests:
  `rt.callCallable` (the one funnel to both engines' `callFromBuiltin` and `callStandalone`),
  the nested path of the API's `rt.call`, and the async coroutine's `start`/`resumeCoroutine`
  (`src/runtime/coroutine.zig`; a fault on resume leaves the coroutine suspended). It faults with `LimitExceeded(native_stack)` when
  `stack_base - @frameAddress() > max_native_stack_bytes`. The fault is uncatchable like the
  other limits and unwinds the same way `call_depth` does today, so nothing new is needed.
- Engine- and mode-independent: bytes are bytes, so no per-engine constant to keep measured.
  Cost: one subtraction and compare per crossing (crossings already allocate a VM or push
  tasks). Plain JS recursion stays bounded by `max_call_depth`/`max_stack_slots`, unchanged.
- Contract for embedders (D15, `limits.zig` doc comment): the thread running zqjs needs
  `max_native_stack_bytes` plus headroom for one crossing and the host's own frames, at least
  128 KiB in Debug (one Debug crossing is ~72 KB). 4 MiB fits the 8 MiB main thread and
  `std.Thread`'s default; a host on a smaller thread lowers it (e.g. 128 KiB on 256 KiB).
- At the default, crossings allowed: Debug ~58 (tree-walker) / ~85 (VM), ReleaseFast ~165 /
  ~1 100. Deep recursion *through callbacks* is rare in real code; Node allows ~11k but does
  not nest native frames per crossing like model B does.
- Test: `tests/interpreter_test.zig` "native→JS recursion stops cleanly even when the host
  thread has a tiny stack": 256 KiB thread, budget 128 KiB, `map` and plain `async`
  recursion, both engines expect `LimitExceeded(native_stack)`. Before this entry it crashed the `interpreter_test` binary.
- C API: `ZQJS_LIMIT_NATIVE_STACK` (12) reports the fault, and `zqjs_limits` gets no field:
  it is embedded in the versioned `zqjs_options` before trailing fields, so a new field would
  move them. In ABI 1.2.0 (M29), `zqjs_options` gains a trailing `max_native_stack_bytes`
  field (default 4 MiB, gated by `struct_size`) so C hosts can configure it while 1.0/1.1
  callers stay binary-compatible.

*Alternatives considered.*
1. **A count of nested run loops (`max_native_depth`) with a measured cost per level.**
   Simple, but one default can't fit both a 72 KB Debug tree-walker crossing and a 3.6 KB
   ReleaseFast VM one: sized for Debug (~64) it caps release builds 14× below what the stack
   allows; sized for release it crashes Debug. The constants also drift with every change to
   the run loops, and it still assumes a stack size.
2. **Lower the effective depth for crossings** (charge each crossing N units of
   `max_call_depth`). The same problem as 1, plus it couples two unrelated budgets.
3. **Lower `max_call_depth`.** Penalizes plain recursion, which costs no native stack since
   D59, and still doesn't know the thread's stack size.
4. **Read the thread's real stack bounds** (`pthread_get_stackaddr_np`/`pthread_getattr_np`/
   `GetCurrentThreadStackLimits`) and fault near the guard page, with no limit to configure.
   The best behavior, and what V8 does, but std 0.17.1 exposes none of these, so it means
   per-OS `extern` code (and Zig's own non-libc threads on Linux have no pthread attrs). Could
   later become the default *value* of `max_native_stack_bytes` without changing this design.
5. **No nesting at all** (resumable built-ins, D51's model A). Removes the problem instead of
   bounding it, but rewrites every callback-taking built-in; out of scope.

*Follow-up, independent of the bound:* the Debug VM run loop frame (~47 KB) and the
tree-walker's ReleaseFast frame (~25 KB, 7× the VM's) are large; moving cold opcode/task arms
out of line would raise the number of crossings any budget allows.
