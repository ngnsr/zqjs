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

## D7. Heap: one allocation interface *(planned, M3/M8; binding from the start)*
**Decision.** `runtime/heap.zig` is the only code that touches the runtime's backing allocator.
- `heap.new(T) !*T` creates GC objects. **It is the only safe point**: a collection can start
  only inside `heap.new`.
- `heap.allocator()` is a counting `std.mem.Allocator` for object-internal buffers (property
  tables, string data, array elements). It counts bytes and enforces the heap limit but
  **never collects**.

`Runtime` exposes no raw allocator. `zig build check` greps for raw allocator use outside
`heap.zig`.
**Why.** When the GC arrives, every allocation is already accounted for, and "can a GC happen
here?" has a one-line answer: *only if `heap.new` can be reached.*

## D8. GC: non-moving, precise, stop-the-world mark-and-sweep *(planned, M8)*
**Object header.** `Obj { kind, marked, next: ?*Obj, gray_next: ?*Obj }`. `next` links every
live object (the sweep list). `gray_next` links the gray worklist (D9).

**`heap.new(T)`:**
1. If `bytes_allocated + size > next_gc` (or `-Dgc-stress`), collect.
2. If still over `Limits.max_heap_bytes` → `error.LimitExceeded`.
3. Allocate, **initialise every field to a traceable state** (empty maps, `undefined` values,
   null pointers), link into `next`.

*Invariant:* every object in the list is traceable at all times, so a failed allocation halfway
through a larger construction never leaves a half-initialised object for the GC to trip over.

**Roots.** VM value stack `[0..sp]`; frames (closure of each frame); `vm.exception`; global
object; the *permanent atom set* (`rt.atoms.common`, e.g. `"length"`, `"prototype"`); the
temporary-root stack (D10a); host handles (`rt.persist`). The weak atom table is **not** a
root (D11).

**Compiler-created values.** GC is paused (`heap.pause()`/`defer heap.unpause()`) for the
whole compilation. Constants and nested protos therefore can't be collected while they are only
referenced from compiler state. The finished proto is returned to the caller, who must root it
before the next `heap.new`. *Trade-off:* compile-time garbage lives until compilation ends, which
is acceptable; the alternative (registering compiler state as roots, as clox does) adds rooting
obligations to the most complex code.

**Tracing rules.**

| type | marks |
|---|---|
| String | nothing |
| Object | prototype; for each property: **key atom and value** |
| Array | elements; plus Object rules for named properties |
| FunctionProto | every constant (strings, numbers, nested protos), property-name atoms used by bytecode, name |
| Closure | proto, every cell |
| Cell | value |
| NativeFunction | name atom, optional `data: Value` |

**Sweep.** (1) remove unmarked strings from the weak atom table, (2) walk `next`, `deinit` +
free unmarked objects, clear marks on survivors, (3) `next_gc = max(live * 2, min_gc)`, capped
at the heap limit.

**Debug-only checks.** Freed objects are poisoned (`kind = .freed`, body `0xAA`) and every
`obj.as(T)` asserts the kind. `heap.verify()` (runs after each collection in stress mode)
re-walks the roots and asserts every reachable pointer is in the `next` list and not freed.

## D9. GC worklist: intrusive gray list, no allocation during GC
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

## D10. Rooting discipline *(planned, M3–M8; applies to all runtime code)*
**Invariant.** *A GC pointer held in a Zig local (or any non-root location) across a call that
may reach `heap.new` must be reachable from a root at the time of that call.*
A function "may collect" if it takes `*Heap`, `*Runtime` or `*VM` and allocates directly or
transitively. Functions that cannot collect take no heap parameter.

**(a) Temporary roots.**
```zig
const m = heap.tempMark();
defer heap.tempRestore(m);      // also runs on every error path
try heap.pushTemp(obj.value()); // capacity reserved up front; see Limits
```
**(b) Partially constructed objects.** `heap.new` returns an object that is traceable but **not
rooted**. If construction continues with another `heap.new` (e.g. an array of fresh objects),
push the parent first. Internal buffers allocated through `heap.allocator()` never collect, so
`try obj.props.put(heap.allocator(), k, v)` is safe without rooting `obj`, provided `k` and `v`
are already reachable.
**(c) Nested constructors.** A constructor that calls another constructor roots its own
result before the inner call. Example: `newError(msg)` = `new(Object)` → **push** →
`newString(msg)` → set property → pop.
**(d) Native functions.** `this` and arguments live on the VM stack (rooted) and are read via
`ctx.arg(i)`, never through a slice (D12). A native that creates more than one object pushes
temporaries. Its return value is pushed by the VM before any other allocation.
**(e) Error paths.** `heap.new` may run a collection *and then* fail with `OutOfMemory` or
`LimitExceeded`. So an `errdefer` that touches an unrooted GC pointer after a failed `heap.new`
is a use-after-free. Rule: `errdefer` blocks only touch rooted objects or non-GC memory; the
temp stack is restored by `defer`, not by hand.
**(f) Exceptions.** A thrown value is stored in `vm.exception` (a root) *before* returning
`error.Thrown`.

**Enforcement.** We considered a debug-mode "GC epoch" wrapper type that asserts no collection
happened since a pointer was loaded. It catches bugs at the access site but adds a wrapper to
every pointer use. Rejected for now in favour of: `-Dgc-stress` (collect on *every*
`heap.new`) + poisoning + `heap.verify()` + Guard Malloc. Revisit if stress mode misses bugs.

**Targeted stress tests (M8, all under `-Dgc-stress`).**
- native function creating two objects and linking them (forgotten temp root ⇒ poisoned read)
- array literal `[{}, {}, …]` and nested object literals `{a:{b:{c:{}}}}`
- string concatenation in a loop; closures capturing cells in a loop
- `newError` path (nested constructor)
- exception thrown while temporaries are pushed: assert temp-stack depth restored
- every allocation failing once (`checkAllAllocationFailures` over a script run): no leak, no
  crash, temp stack balanced

## D11. Atoms (interned property names) and the weak atom table *(planned, M7/M8)*
**Decision.** Property keys are atoms: interned `String` objects, compared by pointer. The
intern table is **weak**, so it does not keep atoms alive.
**How keys stay alive.** Liveness of an atom comes only from strong references: an object's
property map marks its *keys* as well as its values; a proto marks the atoms its bytecode uses;
`rt.atoms.common` is a root. After marking, before sweeping, unmarked atoms are removed from the
intern table, so the table never holds a dangling pointer.
**Why weak.** A strong table leaks every dynamically generated key (`o["k" + i]`).
**Cached data.** Each atom caches `hash` and `array_index: ?u32` (D13).
**Regression tests (M8).**
- 10 000 keys `"k"+i` set on one object, collect 5×, read all back (keys kept alive by the object)
- same keys, object dropped, collect: intern table shrinks to baseline
- `delete o[k]`, collect, re-intern `k`: a fresh atom works as the key again
- key used only as a bytecode constant (`o.someName`) survives collection with no object holding it
- atom table cleanup runs before sweep (verify: no table entry points to a poisoned object)

## D12. VM stack: growable, addressed by index *(planned, M5/M6)*
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

## D13. Object properties: insertion-ordered map + spec key order *(planned, M7)*
`std.ArrayHashMapUnmanaged(*Atom, Property)` keeps insertion order. `delete` uses
`orderedRemove` (O(n), acceptable). `ownKeys()` yields array-index keys (canonical numeric
strings ≤ 2³²−2) ascending, then other string keys in insertion order. No hidden classes.
Arrays are dense; creating a hole is `Unsupported` (D14).
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
only sets a floor. Locally: `brew pin zig`. CI (once a repository exists): `mlugg/setup-zig`
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

## D22. `for (let …)`: one slot now, per-iteration copies in M6
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
**Not verified, so not claimed:** real x86 hardware (Rosetta translates x86 code but isn't an
x86 CPU), Linux/Windows, WebAssembly, 32-bit x86 (where x87 extended precision could cause
double rounding), or other compiler versions. Run `zig build pow-bits -Dtarget=…` there and
compare with the hash above before relying on bit-identity.

**Consequence:** where node is 1 ulp off, ZQJS prints a different last digit
(`0.5 ** -0.5`: ZQJS `1.4142135623730951`, the correctly rounded √2; node `1.414213562373095`).
That is documented in LANGUAGE.md as a known deviation, not a bug.

## D26. TDZ marker: slots are `?Value`
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
limit still bounds it). The M4 constant pool creates each literal once.

## D31. Test layout
Small unit tests stay in `src/` next to the code they test (Zig's convention: they can test
private functions). Everything else lives in `tests/`, behind one root (`tests/all.zig`) and
the public `zqjs` module: whole-pipeline allocation-failure and fuzz tests, syntax cases,
node-generated golden tables (`tests/ops`) and whole-program differential tests (`tests/diff`).
`zig build test` builds exactly two test binaries.
