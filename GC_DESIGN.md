# Garbage collection: design (M8 and after)

Status: **proposal for review**, before any M8 code. Once approved, the decisions here move
into DESIGN_DECISIONS.md (revising D7, D8, D10 and D11 where noted) and this file stays as the
GC's reference. It covers the collector M8 builds (stop-the-world, non-moving, precise
mark-and-sweep) and the interfaces that let incremental marking (M8.1) and generations (M8.2)
be added later without changing the object model.

Contents: 1 goals · 2 invariants · 3 object inventory · 4 roots · 5 safepoints and allocation ·
6 collection phases · 7 barriers · 8 allocation strategy · 9 scheduling and observability ·
10 failure behaviour · 11 testing · 12 per-type review · 13 the road after M8 · 14 decisions

---

## 1. Goals and non-goals

**Goals (M8).** Reclaim unreachable memory during a run, so a program whose *live* data fits
the heap limit can run indefinitely however much garbage it makes. Exact: never free a
reachable object, never keep an unreachable one past the next full collection (except atoms
held by the weak table, which never keeps anything alive). Deterministic: the same program
collects at the same points, every run, on every machine. Observable: counters a benchmark can
compare. Testable: stress modes that turn rooting mistakes into immediate, reproducible failures.

**Non-goals (M8).** Short pauses (M8.1), cheap minor collections (M8.2), moving or compacting
objects (M8.3, research only), concurrent marking (later), finalizers (never planned).

**Why not start with a generational or incremental collector.** Both are layers on the same
foundation: a precise root set, one way to enumerate an object's references, and every reference
store going through one place. Getting those exact is M8's job; the first collector on top is
the simplest one that uses all three, so its bugs are foundation bugs, found early.

---

## 2. Invariants (non-negotiable)

Every runtime change from M8 on must keep these. Each is checked by a test, a stress mode or a
debug assertion (section 11).

- **I1 Safepoints only.** A collection runs only at a *safepoint*: in the VM, at the start of an
  instruction; in the tree-walker, at the start of a statement or expression evaluation (where
  each already charges its budget step). Never inside an allocation, a native, `object.zig`,
  the compiler or the verifier.
- **I2 Precise roots at safepoints.** At a safepoint, every value the program can still use is
  reachable from the root set (section 4). Nothing live exists only in a Zig local.
- **I3 One store path.** After an object is constructed, every store of a reference into it goes
  through the heap's store functions (section 7). Construction (filling a new object before
  anyone else can see it) is the only exception. A test greps the sources for violations.
- **I4 Collection can't fail.** Marking, weak-table cleanup and sweeping allocate nothing and
  return no errors.
- **I5 Objects don't move** (M8 to M8.2). Pointers to heap objects stay valid while the object
  lives.
- **I6 Atoms are weak.** The atom table never keeps an atom alive; it is cleaned before the sweep,
  so it never holds a dangling pointer.
- **I7 Freeing is local.** Destroying an object frees memory it owns and touches nothing else.
  There are no finalizers.
- **I8 One thread per runtime.** A Runtime and its heap are used by one thread at a time. (The
  tree-walker runs on its own thread, but the caller waits for it: still one at a time.) No
  global or thread-local GC state, so a later concurrent collector isn't ruled out by design.

---

## 3. Object inventory (what exists after M7)

| kind | owns | references (edges, `forEachChild`) | created by |
|---|---|---|---|
| String | UTF-16 units | none | `newString`, `intern` (atom) |
| Atom (a String with `atom != null`) | as String | none; kept alive by the objects using it as a key, *not* by the table | `intern`, `internAscii` |
| Cell | | its value | VM: `new_cell`, `box_local`, `fresh_cell` |
| Closure, VM | captures slice | captured cells; its Proto is not a heap object (a root, section 4) | VM: `make_closure` |
| Closure, tree-walker | | its environment record | tree-walker: function declarations and expressions |
| Env (tree-walker) | values | parent record, binding values | tree-walker: scope entry, per-iteration copy, named expressions |
| Object, ordinary | property table | prototype; each property's key atom and value | literals, `Object.create`, built-ins |
| Object, array | elements, property table | prototype; elements; named properties | literals, `Object.keys` |

`heap.forEachChild` already enumerates exactly these edges (one exhaustive switch, unit-tested
per kind in M7). Adding a kind without extending it fails to compile.

---

## 4. The root set

Everything here is enumerated at the start of each collection (section 6). **The list is the
review's main object**: an omission here is a use-after-free.

**Runtime**
- `realm`: the 8 built-in objects (prototypes and the `Object`/`Array` namespaces). The natives
  stored in them are static, not heap objects.
- `exception.message`: the pending exception's message string.
- `unsupported_name`: the atom naming an unsupported built-in.
- `joining`: arrays being converted to strings. Only non-empty *inside* an instruction, never at a
  safepoint (asserted empty when a collection starts, instead of being treated as a root).
- Registered Protos: the Proto tree being run. Each Proto's string constants are roots (D9).
  Protos aren't heap objects (they belong to the compile result), so `runSource` registers the
  tree with the runtime for the duration of the run.
- Host handles (M9): values the embedder holds, registered and released explicitly.

**VM** (all values live in its stacks by construction, so I2 holds at each instruction start)
- operand stack `stack[0 .. sp]`
- locals `locals[0 .. locals_len]`: plain values, and cells (captured bindings)
- every frame: its closure (which keeps its captures and its Proto) and `this`

**Tree-walker** (the hard part: it holds values in Zig locals while it recurses)
- a **shadow stack** `it.roots` of values and environment records. Every value or environment
  the tree-walker holds in a Zig local *across a sub-evaluation* is pushed there first and
  popped with `defer`. The 15 places today: the left operand of a binary operator; a call's
  callee, receiver and arguments; a member's base and evaluated key; an `op=` target's old value;
  the array or object a literal is building; the saved environment and `this` across a call or
  block; a `for` loop's previous iteration record; a function expression's own-name record.
- the current environment `it.env`, the current `this`, the pending return value `it.ret`

**Not roots, deliberately**
- The atom table (I6).
- Compiler state: the compiler allocates strings but runs before the VM, with no safepoint inside
  it (I1). Its result is registered as a root before execution starts.
- Natives' locals: natives contain no safepoint (I1), so whatever they allocate is either
  returned (then held by the VM or the tree-walker's shadow stack) or garbage.

**Change from D11.** D11 expected bytecode to keep property-name atoms alive. It doesn't need to:
bytecode stores names as plain ASCII (`Proto.names`) and interns them on use, so an atom
collected in between is simply interned again (atoms compare by content when looked up). The D11
regression test "a key used only as a bytecode constant survives collection" becomes "a property
read by name works across collections that freed its atom".

---

## 5. Safepoints and allocation

**Decision: collect only at safepoints (I1), not inside allocation.** This revises D7, which made
"`heap.new` is the only safepoint". *Why:* if any allocation could collect, every heap pointer
held in a Zig local across *any* allocation would need rooting: in `object.zig` (keys interned
while holding the object), `join` (strings made while holding the array), every native, both
engines and the compiler. That is dozens of sites today and every future one, and each mistake is
a use-after-free that shows up only when a collection happens at that exact point. With
safepoints at instruction / evaluation boundaries:

- the VM needs no extra rooting at all (its stacks are the roots);
- natives, `object.zig` and the compiler need none;
- only the tree-walker needs a shadow stack, because it is the one place that holds values in
  Zig locals across a safepoint.

*Cost:* garbage made *within* one instruction or one evaluation step can't be collected until the
next safepoint. That is bounded: the biggest single steps are a `join` (bounded by
`max_string_length`), `new_array` / a literal (bounded by the operand count) and `Object.keys`
(bounded by the object's size, which is live data anyway).

**Allocation** stays as it is: `heap.zig` is the only code that allocates heap objects (D7); each
allocation is charged before it is made and refused past `max_heap_bytes`. It also adds to the
*allocation debt*: when `bytes` passes `next_gc`, the heap sets `collect_requested`, and the next
safepoint collects.

**The heap limit with a collector.** `max_heap_bytes` keeps meaning "accounted bytes", live plus
garbage not collected yet. So that a program with a small live set never hits it, a collection is
requested well before it: `next_gc ≤ limit − headroom` (headroom: an eighth of the limit). A
program can then fail with LimitExceeded(heap_bytes) only if its *live* data, plus at most one
step's garbage, exceeds the limit. Acceptance test: a loop making garbage forever under a 1 MiB
limit runs until its step budget, on both engines.

---

## 6. Collection phases (M8: stop-the-world)

1. **Start** at a safepoint with `collect_requested`, or when forced (tests, `-Dgc-stress`).
   Assert `joining` is empty.
2. **Mark roots.** Each root object is marked and pushed on the gray list.
3. **Drain.** Pop a gray object; for each child from `forEachChild`, if unmarked, mark it and
   push it. The gray list is *intrusive*: a `gray_next` pointer in every object header, so
   marking never allocates (I4; the "worklist OOM" concern from the M1 review). No recursion,
   so nesting depth is irrelevant.
4. **Weak atoms.** Remove every unmarked atom from the atom table, in place (no allocation).
5. **Sweep.** Walk the object list: destroy unmarked objects (refunding their charge), clear the
   mark on survivors.
6. **Schedule.** `next_gc = clamp(live × growth, min_gc, limit − headroom)`, with `growth` = 2 and
   `min_gc` = 256 KiB (tunable, measured in M8).
7. **Account.** Update the statistics (section 9).

**Header.** `Obj { kind, next, mark: u1 (M8.1: color: u2; M8.2: old: u1), gray_next }`: 8 more
bytes per object. *Alternative:* side mark bitmaps, which need page-structured allocation
(section 8); not before there is a reason.

---

## 7. Barriers

**The API (M8).** Every reference store into an existing heap object goes through one of a few
heap functions (I3):

- `heap.storeProperty(object, key, value)` and `storeElement(array, index, value)`, plus `appendElements`
- `heap.storeCell(cell, value)`
- `heap.storeEnv(env, index, value)` (tree-walker)
- closures' captures and an object's prototype are set only at construction

Each receives the owner, the slot's old value and the new value, which is everything an
insertion barrier (Dijkstra: shade the new value if the owner is black) or a deletion barrier
(Yuasa / snapshot-at-the-beginning: shade the old value) needs, and also what a generational
remembered set needs (an old owner storing a young value). **In M8 the barrier itself is a
no-op**: with stop-the-world marking no store can happen during a collection. What M8 *does*
deliver is that every store goes through these functions, enforced by a test that greps for raw
stores outside `heap.zig`, plus a debug assertion that the owner is a live object (in
`-Dgc-stress` freed objects are poisoned, see 11).

Today's ~25 store sites (`object.zig`, `builtins.zig`, the tree-walker's environment writes, the
VM's cell writes and array appends) move behind these calls as M8's first step.

**Not barriered:** the VM's stacks and locals, and the tree-walker's shadow stack. They are roots,
rescanned at the end of an incremental cycle (M8.1) or treated as part of the snapshot.

---

## 8. Allocation strategy

**M8:** keep individual allocations from the backing allocator, linked in one intrusive list
(as now). It's simple, already accounted, and each object is freed individually by the sweep.
*Alternatives* for later, each needing a measurement first: size-class pages (faster allocation,
better locality, side mark bits, a natural nursery for M8.2), or bump allocation in a nursery
(needs moving, so M8.3). Object-internal buffers (property tables, element lists) keep using the
counting `heap.allocator()`.

---

## 9. Scheduling and observability

`Heap.stats`, readable by tests, the benchmark tool and (M9) embedders:

- `collections`
- `bytes_allocated` (cumulative), `bytes_freed` (cumulative)
- `live_after_last` (bytes surviving the last collection), `peak` (highest accounted)
- `marked`, `swept` (objects): deterministic work units, which is what *pause cost* means here.
  Wall-clock pause time needs a clock the runtime doesn't have (no `std.Io` in it), so the
  benchmark tool times collections from outside.
- later: `promoted` (M8.2), `increments` (M8.1)

`zig build bench` gains columns `collections` and `peak`. With a collector, `peak` drops below
`allocated` wherever garbage is collected; on the tree-walker benchmarks it should fall by orders
of magnitude.

---

## 10. Failure behaviour

- A collection can't fail (I4). It has no error path.
- Allocation fails as today: LimitExceeded(heap_bytes) or OutOfMemory, before anything changes
  (charge first, allocate second). The engines' precise-fault guarantees are unaffected.
- A violated invariant is a bug: debug and stress builds panic on it (a store into a freed object,
  a `joining` stack non-empty at a safepoint, a root pointing at a freed object).
- `Runtime.deinit` frees everything, reachable or not, as now.

---

## 11. Testing

- **`-Dgc-stress`**: collect at *every* safepoint. The whole suite on both engines, in CI next to
  `-Dstack-stress`. A missing tree-walker root shows up at the next evaluation, not when a
  collection happens to land there.
- **Zombie mode** (with gc-stress): freed objects aren't returned to the allocator but turned
  into tombstones (`kind = .dead`, payload poisoned); every heap accessor and store function
  asserts it is not touching one. A use-after-free is a deterministic panic naming the object
  kind, not memory corruption.
- **Heap verifier** (stress builds, after every collection): every object reachable from the roots
  is marked; no live object or root points at a tombstone; the atom table holds only marked atoms.
- **The D10/D11 regression list**, updated: 10,000 keys `"k"+i` on one object survive five
  collections; the same keys with the object dropped shrink the atom table to its baseline;
  `delete o[k]`, collect, reuse `k`; a property name used only in bytecode works across
  collections that freed its atom; the atom table is cleaned before the sweep.
- **Garbage under a small limit**: loops making strings, closures, environments and objects
  forever under a 1 MiB heap run until the step budget, on both engines.
- **Every root kind** (section 4) gets a test that collects while that root is the *only*
  reference: an exception message printed after collections, a closure captured only by a frame,
  a tree-walker operand held across a call that collects, the realm, a registered Proto's string
  constants, `this` of a suspended frame.
- **Differential fuzzing under gc-stress**; allocation failure at every point, as now.
- **Benchmarks:** the eight workloads with `collections` and `peak`; steps unchanged (the collector
  doesn't charge steps).

---

## 12. Review against every M7 type

| type | allocated where | can be held by (roots) | mutated by | freed |
|---|---|---|---|---|
| String | `newString`; compiler constants | stacks, locals, cells, envs, properties, elements, exception, Proto constants | never (immutable) | sweep |
| Atom | `intern*` | property keys (edge), `unsupported_name`, transiently a key in a native or `object.zig` (no safepoint there) | never | sweep, after removal from the table (I6) |
| Cell | VM | locals (slot kind `cell`), closure captures | `storeCell`: `set_cell`, `init_cell` (`fresh_cell` and `box_local` make new ones) | sweep |
| Closure (VM) | `make_closure` | stacks, locals, cells, properties, frames | never after construction | sweep |
| Closure (tree-walker) | function declarations and expressions | envs, shadow stack, properties | never after construction | sweep |
| Env | scope entry, per-iteration copy, named expressions | `it.env`, shadow stack, closures, parent links | `storeEnv`: declarations, assignments, parameters | sweep |
| Object | literals, `new_object`, `Object.create`, realm | everywhere values go; `realm` | `storeProperty` (set, define); delete removes (no barrier needed for M8/M8.1 with an insertion barrier; Yuasa would shade the removed value) | sweep (frees its table) |
| Array | literals, `new_array`, `Object.keys` | as Object | `storeElement`, `appendElements` (push, set, literals); pop and truncation remove | sweep |
| Proto (not a heap object) | compiler | registered tree, closures | never | with the compile result, after the run |

Two follow-ups this review turned up: deletions (`delete`, `pop`, `length` truncation) also go
through the store API, so a deletion barrier is possible in M8.1; and `Object.keys` builds its
result inside one native, so its intermediate array needs no root (no safepoint there, I1).

---

## 13. The road after M8

What each later step needs from M8, so that none of them changes the object model:

- **M8.1 incremental marking:** a marking state machine stepped at safepoints with a work budget
  (objects per step); a tri-color invariant kept by a barrier in the store functions; a short
  final pause to rescan the roots (stacks are not barriered); allocation during marking is
  black. Uses: the header's color bits, the store API, the gray list, safepoints.
- **M8.2 generations (non-moving):** a young list and an old list; a minor collection marks from
  the roots plus the remembered set (old owners that stored young values, recorded by the same
  barrier) and sweeps only the young list; survivors are promoted by setting a bit, without
  moving. Uses: the header's old bit, the store API, the per-list sweep.
- **M8.3 compaction (research):** moving needs every pointer updated, including Zig locals in
  natives and engines, so it would need handles or a rule that natives never hold pointers. Not
  implemented without a measured need (fragmentation, locality).
- **Concurrent marking (later):** the barrier becomes atomic, marking runs on another thread, and
  safepoints become handshakes. I8 keeps that possible.

---

## 14. Decisions to approve

1. **Collect only at safepoints** (VM instruction starts, tree-walker evaluation starts), never
   inside allocation (revises D7). The tree-walker gets a shadow stack; nothing else needs rooting.
2. **M8 is stop-the-world, non-moving, precise mark-and-sweep** with an intrusive gray list (+8
   bytes per object header).
3. **The store API (barrier hook) is introduced and enforced in M8**, as a no-op barrier, so
   M8.1 and M8.2 only change what the hook does.
4. **Protos stay outside the heap**, registered as roots while running; bytecode names stay ASCII,
   so bytecode keeps no atoms alive (revises D11's expectation and its test).
5. **Heap-limit semantics:** accounted bytes include uncollected garbage; collections are
   scheduled with an eighth of the limit as headroom.
6. **No finalizers, one thread per runtime**, no global GC state.
7. **Observability:** deterministic counters (`collections`, bytes, `marked`/`swept`), wall-clock
   only in the benchmark tool.
8. **Stress:** `-Dgc-stress` with zombie mode and the heap verifier, in CI.
