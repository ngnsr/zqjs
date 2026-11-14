# M8 implementation plan: garbage collector

Status: **in progress**. [GC_DESIGN.md](GC_DESIGN.md) is the design (approved as the
baseline; section numbers below refer to it). This file is the work breakdown: phases, the
exact files and sites each touches, the tests that gate it, and the review checklist. It is
deleted when M8 ships and its content has moved into ROADMAP.md and DESIGN_DECISIONS.md.

Rules that hold for every phase: `zig build test` passes before a commit, existing tests are
rewritten (never deleted) only when the behaviour they assert legitimately changes, and every
phase keeps both engines and every build mode working. GC code is not delegated (AGENTS.md).

## What ships and what doesn't

**In:** a stop-the-world, non-moving, precise mark-and-sweep collector; collection only at
safepoints; the store API (no-op barrier) with source enforcement; weak atoms; registered
Protos as roots; deterministic stats; `-Dgc-stress` with zombie mode and a heap verifier; the
D10/D11 regression lists; benchmarks showing the drop; docs and tag `m8`.

**Out:** incremental marking (M8.1), generations (M8.2), moving/compacting (M8.3), concurrent
marking, finalizers, host handles (M9). The store API is shaped so each of those changes only
what the hook does (GC_DESIGN §13).

## Phases

Each phase is one reviewable commit (P0 may be two: docs, then code).

### P0. Store API and foundation — no collection yet *(done)*

Behaviour-neutral. This is GC_DESIGN §7's "M8's first step", and it establishes a real
invariant: the store API is the *only supported way* to mutate a GC-visible reference.

- `runtime/heap.zig`: `storeProperty`, `defineProperty`, `removeProperty`, `appendElement`,
  `appendElements`, `storeElement`, `shrinkElements`, `popElement`, `storeCell`, `storeEnv`.
  Covered: property stores and deletes, element stores/appends/truncation/pop, cell updates,
  environment updates. Prototype and capture writes stay inside `heap.zig` constructors (there
  are no others today; the scan keeps it that way). Each function takes the owner, so a future
  insertion/deletion/generational barrier reads what it needs without changing call sites.
- Move every store (~25 sites) behind them: `runtime/object.zig` (set/define/delete/length),
  `runtime/builtins.zig` (method table, push/pop, Object.keys), `vm/vm.zig` (cell writes,
  array literal construction), `interp/treewalk.zig` (env writes, parameter binding,
  function hoisting, named expressions). No hidden raw writes remain in constructors or
  built-ins; construction (filling a new object before anyone can see it) stays the one
  exception, as in GC_DESIGN §7.
- `tests/gc_test.zig` (new, imported by `tests/all.zig`): the I3 source scan — no `.props.put`
  / `.kind.array.append` / `items[i] =` / `.value =` store outside `heap.zig` in the four
  heap-touching files. Reads stay direct; the exemption list is documented in the test. The
  scan is by pattern, not by the compiler (Zig has no field privacy), so review also routes
  new sites through the API.
- `DESIGN_DECISIONS.md`: rewrite D7, D8, D9, D10 and D11 to the approved design (safepoints
  only; no temp roots; weak atoms; Protos as roots; +8-byte header; scheduling; stats);
  `GC_DESIGN.md` status becomes "approved".

### P1. Collector core, VM collecting *(done)*

Done as planned, plus, from the P1 review: a cross-type chain test (a value reachable only
through object → array → VM closure → cell → object → prototype, and tree closure → env →
parent env, survives a collection that frees garbage of every kind pointing into it); and an
allocation-free proof (a collection with the backing allocator failing every request makes
zero allocations and reuses the atom table's storage). Two findings while building it: `Vm.init`
returns the VM by value, so the VM registers its roots at each safepoint rather than in
`init` (a pointer taken there would point at a copy), and unregisters in `deinit`; and a
mutation test (locals left unmarked) is caught by the root tests, but as a crash on the freed
memory rather than a clean failure, which is what P3's zombie mode turns into a deterministic
panic. Measured: VM peak heap falls from 14-30 MB to ~260 KB on the garbage-heavy benchmarks,
steps unchanged; every diff program matches node on the VM with a collection at every
safepoint.

- `Obj`: `marked: bool`, `gray_next: ?*Obj` (header 16 → 24 bytes). All constructors default
  them; `destroy` unchanged.
- `Heap`: `next_gc`, `collect_requested`, `Stats { collections, bytes_freed,
  live_after_last, marked, swept }`; `requestCollect` sets the flag when `bytes` passes
  `next_gc`; `collect(roots)` runs mark → drain → atom cleanup → sweep → schedule → stats.
  Marking is the existing `forEachChild`, iterative through the intrusive gray list; nothing
  in the collector allocates (I4).
- Scheduling: `next_gc = live + min(max(live, 256 KiB), (limit − live) / 2)` (revised from `clamp(live × 2, 256 KiB, limit − limit/8)`, see D8), recomputed after
  each collection; `requestCollect` at every allocation that pushes `bytes` over `next_gc`.
- Atom table cleanup: after marking, clear retaining capacity and re-insert the marked atom
  strings found in the object list (`putAssumeCapacity`), so no allocation and no dangling
  entries (I6). Atoms become weak.
- Roots: `Runtime.realm`, `Runtime.exception.message`, `Runtime.unsupported_name`; the
  registered Proto tree (`Vm.init` registers, `Vm.deinit` unregisters; the script Proto's
  constants and nested functions are walked); VM operand stack, locals, each frame's closure
  and `this`. `Runtime.collect()` (tests only, no engine live).
- Safepoint: `Vm.step` before the instruction (after the fault/halt checks, before the budget
  charge, so the collector never charges a step). The contract, stated in GC_DESIGN §5 and
  D8: *no collection can occur during instruction execution — every GC-managed reference an
  instruction needs is either reachable from the root set at the safepoint that started it,
  or was allocated after that safepoint.*
- Tests: `tests/gc_test.zig` grows unit tests for mark/sweep/atoms/scheduling; the D11
  regression list (10 000 keys kept alive by an object; dropped object shrinks the table;
  delete-collect-reuse; a name used only by bytecode works after its atom was freed); one test
  per VM root kind; garbage-under-a-1-MiB-limit for the VM. Tree-walker does not collect yet
  (its safepoint isn't wired), so its tests are unchanged.
- **Proto/atom lifetime tests** (the reviewer's list, all in P1): a string constant survives
  collections while its Proto executes; nested function Protos keep their constants; an atom
  referenced by a live object survives; a dead atom is gone after the collection; the atom
  table's capacity is reused without allocation during cleanup; Proto registration is removed
  when the VM is destroyed. Subtlety pinned by a test: registration holds the same `*const
  Proto` its owner owns (the script `runSource`/`bench` keeps alive), never a temporary.

### P2. Tree-walker roots *(done)*

Done as planned. Exact site list from the code: binary left operand; `x op= e` old value;
member base, evaluated key, converted key atom and old value; array/object literal under
construction and its key atoms; callee, receiver and each argument; the caller's environment
and `this` while a closure's body runs. Not needed, and why: blocks and `for` loops push a
record whose parent is the saved environment (reachable through the chain); return values
are consumed before the next safepoint unless they become a held value above. Tests: 13
node-checked site programs on both engines collecting at every safepoint (calls, recursion,
receivers, literals, returns, closures, per-iteration bindings), every diff program on the
tree-walker collecting at every safepoint, exceptions and limits mid-evaluation, allocation
failure at every point with collection forced, garbage under a small limit (a mutation that
stops the tree-walker collecting fails it). Test cost: two garbage tests first ran 2M steps
under std.testing.allocator (which traces every allocation) and took minutes; they now run
50k steps under a 128 KiB limit, allocating several times the limit, which proves more in
seconds. Integration suite back to ~1 min.

The risky phase: the tree-walker holds values in Zig locals across sub-evaluations.

- `Interpreter.roots: std.ArrayList(*Obj)` (shadow stack) plus `it.env`, `it.this`, `it.ret`
  as roots; a `safepoint` at the start of `exec` and `eval`, after `enter()`, before
  `rt.step()`.
- Push before every sub-evaluation that can collect; pop with `defer`, so symmetry holds on
  *every* exit path — normal return, Thrown, Unsupported, LimitExceeded and allocation
  failure. A stress-build assertion checks the shadow-stack depth is unchanged across every
  `exec`/`eval`; the per-site tests (GC_DESIGN §11) catch a value held without a push.
- The 15 sites (GC_DESIGN §4): binary left operand; callee, receiver, each evaluated argument;
  member base and key value; `op=` old value and target base/key; array literal under
  construction; object literal under construction and its key atom; block/loop saved
  environment and `this`; the per-iteration record; a named function expression's record.
- Tests: one per shadow-stack site (a value whose only reference is the shadow stack survives
  a collection that happens in the sub-evaluation), the D10 list adapted to safepoints (array
  and nested object literals, concatenation in a loop, closures capturing cells in a loop),
  garbage-under-a-small-limit on the tree-walker, engine agreement with collection forced.

### P3. Stress modes, zombie, verifier, CI

- `-Dgc-stress` (build option, like `-Dstack-stress`): collect at every safepoint.
- Zombie mode (with gc-stress): freed objects become `kind = .dead` tombstones with poisoned
  payload, kept until `Heap.deinit`; every heap accessor and store asserts the object is not
  dead, so a use-after-free is a panic naming the object kind. `destroy` frees the payload
  buffers but not the header.
- Heap verifier (stress, after every collection): every reachable object is marked; no live
  object or root points at a tombstone; the atom table holds only marked atoms; the shadow
  stack is balanced.
- OOM injection over runs with collection active; `checkAllAllocationFailures` still passes.
- CI: `zig build test -Dgc-stress` (and ReleaseSafe) next to `-Dstack-stress`. The mode stays
  **collect at every safepoint** — that is what finds missing roots. If the full suite is too
  slow, the stress tests move to a dedicated CI job; the mode is never weakened.
- Rewrite the one existing test whose premise the GC changes: the `'' + n++` loop under a
  64 KiB limit no longer exhausts the heap (the strings are garbage); the replacement
  accumulates the strings so the accounting claim (per-allocation overhead) is still tested,
  and a new test asserts the garbage loop runs to its step budget. (Approved in the plan
  review.)

### P4. Acceptance, benchmarks, docs, tag

- GC_DESIGN §11 acceptance: every root kind collected-while-sole-reference; D10/D11 lists;
  garbage loops (strings, closures, environments, objects) under 1 MiB until the step budget
  on both engines; differential fuzzing under gc-stress.
- `tools/bench.zig`: add `collections` (peak already exists); regenerate `bench/baseline.txt`.
  Steps must be unchanged; `peak` drops, dramatically on the tree-walker. Wall-clock pause
  time stays outside the runtime (no clock in it).
- Docs: README status and language list; ARCHITECTURE (heap/GC row, ownership); ROADMAP (M8
  done, required tests, remove the GC debt rows); LANGUAGE heap-limit paragraph;
  DESIGN_DECISIONS statuses; GC_DESIGN status "built"; tag `m8`.

## Scheduler and limits: known consequences

- `max_heap_bytes` counts live plus not-yet-collected garbage. Collections trigger at most
  halfway between the live size and the limit, so uncollected garbage at a safepoint is at
  most half the remaining room plus one step's garbage, and filling the heap with live data
  costs O(log limit) collections.
- Because allocation never collects (I1), one instruction that allocates more than the
  remaining headroom can fail with `LimitExceeded(heap_bytes)` while enough garbage exists to
  make room. The guarantee is "live + headroom + one step's allocation", not "live". Tests
  use live growth when they want the limit to fire; this is documented in D8 and revisited
  only if a real program hits it (M8.1 retry at a safepoint is the natural fix, not
  collecting inside allocation).
- No new `Limits` fields: trigger constants are collector policy, not user-facing resources.
- No temp roots (D10 is revised): with no collection inside allocation, native functions,
  `object.zig` and the compiler need no rooting; only the tree-walker does.

## Review checklist

1. Root completeness: every entry of GC_DESIGN §4 has a test that collects while it is the
   only reference; an omission is a use-after-free.
2. Sweep order: atoms removed before any atom is freed; verifier checks the table.
3. Accounting: `bytes` after a collection equals the sum of survivors' charges (test), and
   `bytes_freed` is cumulative.
4. Failure paths: `collect` has no error path; an allocation that fails leaves accounting and
   roots unchanged.
5. Determinism: collection points, stats, and the atom rebuild are independent of hash order
   (atom rebuild walks the object list, not the map).
6. `-Dgc-stress` in CI, plus ReleaseSafe and `-Dstack-stress`.
7. Docs consistent: README/ROADMAP/ARCHITECTURE/LANGUAGE/D8–D11/GC_DESIGN.

## Decisions from the plan review (2026-11-14)

1. **P0 establishes an invariant, not just a refactor:** the store API is the only supported
   way to mutate a GC-visible reference, covering properties, elements, deletes, cells and
   environments; prototype/capture writes stay inside `heap.zig`; call sites survive future
   barriers unchanged.
2. **The safepoint contract is written down verbatim** (GC_DESIGN §5, D8), and the heap-limit
   limitation is documented as an accepted trade-off, not hidden.
3. **Proto/atom lifetime gets its own test list in P1** (six tests, plus the registration
   lifetime subtlety).
4. **P2's shadow stack must be symmetric on every exit path**, checked by a stress assertion.
5. **`-Dgc-stress` stays every-safepoint.** If CI is too slow, split the stress tests into a
   dedicated job; never lower the frequency.
6. **Strategy table committed** (GC_DESIGN §13): M8 stop-the-world → M8.1 incremental → M8.2
   generational → concurrent only if benchmarks justify. M8 preserves the store API, the
   tracing interface and the root model so each step is a change of policy, not of model.

## Open questions

None blocking. The three questions from the draft plan were resolved in review (test rewrite
approved; stress frequency stays; CI job split decided after measuring P3).
