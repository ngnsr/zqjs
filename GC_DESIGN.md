# Garbage collection: design (M8 and after)

Status: **built in M8, generational since M8.1** (approved designs; the decisions are in
DESIGN_DECISIONS.md D7–D11 and D42–D45, revised where noted, and the tests and findings in
ROADMAP.md). This file stays as the GC's reference.
- §1–§14: the collector M8 built (stop-the-world, non-moving, precise mark-and-sweep), and
  the interfaces that let later collectors be added without changing the object model.
- §15: the generations M8.1 added on top of it (nursery, remembered set, cards, adaptive major
  scheduling).
- Incremental marking (M8.2) is deferred (ROADMAP.md, Direction).

Contents: 1 goals · 2 invariants · 3 object inventory · 4 roots · 5 safepoints and allocation ·
6 collection phases · 7 barriers · 8 allocation strategy · 9 scheduling and observability ·
10 failure behaviour · 11 testing · 12 per-type review · 13 the road after M8 · 14 decisions ·
15 generations (M8.1)

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

**The safepoint contract.** No collection can occur during instruction execution (or during a
tree-walker evaluation step): every GC-managed reference an instruction needs is either
reachable from the root set at the safepoint that started it, or was allocated after that
safepoint. This is what makes temporary values cheap to reason about: an instruction may hold
heap pointers in Zig locals freely, because nothing can collect under it.

**Allocation** stays as it is: `heap.zig` is the only code that allocates heap objects (D7); each
allocation is charged before it is made and refused past `max_heap_bytes`. It also adds to the
*allocation debt*: when `bytes` passes `next_gc`, the heap sets `collect_requested`, and the next
safepoint collects.

**The heap limit with a collector.** `max_heap_bytes` keeps meaning "accounted bytes", live plus
garbage not collected yet. So that a program with a small live set never hits it, a collection is
requested well before it: `next_gc = live + min(max(live, 256 KiB), (limit − live) / 2)`, so the trigger is never past halfway between
the live size and the limit. (Revised in P1 from `limit − limit/8`, which made every safepoint
collect once live data passed that cap: see D8.) A
program can then fail with LimitExceeded(heap_bytes) only if its *live* data, plus at most one
step's garbage, exceeds the limit (with the caveat below). Acceptance test: a loop making
garbage forever under a 1 MiB limit runs until its step budget, on both engines.

**Acknowledged limitation.** Because allocation never collects, uncollected garbage can reach
the trigger (at most half the room left under the limit) before a collection is requested, so a single instruction
that allocates more than the remaining headroom can fail with LimitExceeded(heap_bytes) although
collectable garbage exists (200 MiB of garbage below the trigger, then a 60 MiB join, on a
256 MiB limit). The real guarantee is therefore "live data + headroom + one step's allocation",
not "live data". Accepted for M8 and stated here rather than hidden; the natural fix — an
instruction-level collect-and-retry — belongs to M8.1, not to collecting inside allocation.

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
- closures' captures and an object's prototype are set only at construction, inside
  `heap.zig`; the source scan (I3) keeps any write to them out of every other file

Each receives the owner, the slot's old value and the new value, which is everything an
insertion barrier (Dijkstra: shade the new value if the owner is black) or a deletion barrier
(Yuasa / snapshot-at-the-beginning: shade the old value) needs, and also what a generational
remembered set needs (an old owner storing a young value). **In M8 the barrier itself is a
no-op**: with stop-the-world marking no store can happen during a collection. **Since M8.1 it keeps the remembered set**:
an old owner that stores a young reference is listed once, and its array or property card is
dirtied (§15). What M8 *does*
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
- **Proto and atom lifetime** (the collector-enable boundary, one test each): a string
  constant survives collections while its Proto executes; nested function Protos keep their
  constants; an atom referenced by a live object survives; a dead atom is gone after the
  collection; the atom table's capacity is reused without allocation during cleanup; Proto
  registration is removed when the VM is destroyed, and registration never outlives the
  `Proto` it points at (the VM registers the same script Proto `runSource` owns, not a copy).
- **Shadow-stack symmetry** (stress builds): the tree-walker's shadow stack has the same depth
  after every `exec`/`eval` as before it, on every exit path — normal return, Thrown,
  Unsupported, LimitExceeded and allocation failure. `defer` makes it hold by construction;
  the verifier asserts it.
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

| milestone | collector |
|---|---|
| M8 | stop-the-world, non-moving mark-and-sweep |
| M8.1 | generational collection, non-moving (**built**, §15) |
| M8.2 | incremental marking of major collections (deferred until an embedder needs it) |
| later | concurrent marking, if benchmarks justify it |

The order was swapped after M8's measurements: pauses were linear in the live heap, and most
of the work re-marked long-lived objects, which generations remove.

What each later step needs from M8, so that none of them changes the object model:

- **M8.2 incremental marking:** a marking state machine stepped at safepoints with a work budget
  (objects per step); a tri-color invariant kept by a barrier in the store functions; a short
  final pause to rescan the roots (stacks are not barriered); allocation during marking is
  black. Uses: the header's color bits, the store API, the gray list, safepoints.
- **Generations (non-moving), built in M8.1 (§15):** a young list and an old list; a minor collection marks from
  the roots plus the remembered set (old owners that stored young values, recorded by the same
  barrier) and sweeps only the young list; survivors are promoted by setting a bit, without
  moving. Uses: the header's old bit, the store API, the per-list sweep.
- **M8.3 compaction (research):** moving needs every pointer updated, including Zig locals in
  natives and engines, so it would need handles or a rule that natives never hold pointers. Not
  implemented without a measured need (fragmentation, locality).
- **Concurrent marking (later):** the barrier becomes atomic, marking runs on another thread, and
  safepoints become handshakes. I8 keeps that possible.

---

## 14. Decisions (approved)

1. **Collect only at safepoints** (VM instruction starts, tree-walker evaluation starts), never
   inside allocation (revises D7). The tree-walker gets a shadow stack; nothing else needs rooting.
2. **M8 is stop-the-world, non-moving, precise mark-and-sweep** with an intrusive gray list (+8
   bytes per object header).
3. **The store API (barrier hook) is introduced and enforced in M8**, as a no-op barrier, so
   M8.1 and M8.2 only change what the hook does.
4. **Protos stay outside the heap**, registered as roots while running; bytecode names stay ASCII,
   so bytecode keeps no atoms alive (revises D11's expectation and its test).
5. **Heap-limit semantics:** accounted bytes include uncollected garbage; collections are
   scheduled at most halfway between the live size and the limit (revised in P1, D8).
6. **No finalizers, one thread per runtime**, no global GC state.
7. **Observability:** deterministic counters (`collections`, bytes, `marked`/`swept`), wall-clock
   only in the benchmark tool.
8. **Stress:** `-Dgc-stress` with zombie mode and the heap verifier, in CI — collecting at
   *every* safepoint. If the full suite is too slow, the stress tests move to a dedicated CI
   job; the mode itself is never weakened (a lower collection frequency would hide exactly
   the bugs it exists to find).


---

## 15. Generations (M8.1)

Status: **built in M8.1.** This section is the M8.1 plan as approved through its reviews,
kept with its measurements and proofs. The decisions are D8 (revised) and D42–D45. The numbers
are on an Apple M4, ReleaseFast, `zig build gc-report`. The baselines are in `bench/gc/`:
`baseline-m8.txt`, `baseline-m8.1.txt`, and `baseline-m8.1-libc.txt` (same allocator as M8).

### What the baseline says

| workload (VM) | live after GC | max pause | GC share | pauses > 16 ms |
|---|---|---|---|---|
| game_100k | 43 MB | 24 ms | 28% | 7 |
| game_growing (to 300k) | 111 MB | 73 ms | 35% | 5 |
| game_1m | 426 MB | 308 ms | 58% | 4 |
| game_big_container (1M, one young store per frame) | 261 MB | 157 ms | 45% | 3 |

1. **Every pause traces the whole live heap.** game_growing's per-collection series grows linearly,
   about 0.14 µs per live object. In game_100k, each steady-state collection marks 200k persistent
   objects to free about 290k temporaries that died a frame after they were made.
2. **The heap-doubling schedule defers the cost instead of avoiding it.** In game_1m the frame loop
   never collects: `next_gc` is about 850 MB after setup, so 120 MB of per-frame garbage piles up.
   The result is unbounded memory now and one 300 ms hitch later.
3. **Rescanning a large old array is too expensive to do whole (review point 3).** `gc-report` now
   times one scan of the largest array's children. It reads each child's header, which is what the
   old-bit check does.

   | array | one child scan |
   |---|---|
   | 100k elements | 0.09 ms |
   | 300k elements | 1.2 ms |
   | 1M elements | 4.4 ms |

   The cost is superlinear, because past a few hundred thousand elements the scan no longer fits in
   cache. With per-object remembering, one young store into the 1M array would cost every minor
   collection 4.4 ms, which is 4× the whole pause target. So cards go into P1 rather than waiting
   as a follow-up.

### Generations

- Each object header gets an `old` bit and a `remembered` bit. Both fit in padding next to
  `marked`, so the header doesn't grow.
- The heap keeps two intrusive lists instead of one:
  - `young`: every new object goes here;
  - `old`: everything promoted.
- Nothing moves, as D8 requires (natives, and in M9 the C ABI, hold raw pointers). Promotion
  relinks an object from one list to the other and sets its bit.

**Promotion (point 1): every object that survives any collection becomes old.** That covers both
minor and major collections.

- Invariant **I-gen3**: after any collection, `young` is empty, the remembered set is empty, and
  no card is dirty. The verifier checks it.
- This works because live temporaries at a safepoint are few (a frame's `v` and `label`), so
  promoting them early costs little.
- An age counter is a follow-up, only if the report shows promoted garbage driving the major
  collection rate.

### Minor collection

Stop-the-world, at the same safepoints as today. Its cost is O(roots + remembered work +
young list), with no term for the old generation's size.

1. **Drain the remembered set.** For each remembered owner, clear `remembered`, then scan:
   - an array with cards scans only its dirty cards' elements, then clears the cards;
   - everything else scans all its children, as `forEachChild` does today.

   Young children are pushed onto the gray list, and the owner's `gray_next` is free again.
2. **Mark from the engine roots.** `markObj` returns immediately on an old object, so old objects
   are never traversed.
3. **Drain the gray list.** Only young objects are ever on it.
4. **Sweep `young` only.**
   - An unmarked object is freed, or tombstoned under stress.
   - A marked object is unmarked, gets its `old` bit set, and is relinked to `old`.
   - An unmarked **atom** is promoted instead of freed (see below).

### Remembered set (point 2)

It's an intrusive list through `gray_next`, plus the `remembered` bit. **It records owners, not
edges.** A minor collection scans an owner's *current* contents, so a reference that has since
been overwritten can't keep anything alive.

**Lifecycle:**

| event | effect |
|---|---|
| an old owner stores a young reference (barrier) | if `!remembered`: set the bit, push the owner onto the list. For a carded array, also set the store index's card bit. |
| the same owner stores again, young or not | no list change: the bit makes insertion idempotent, so **no duplicate can ever enter the list** |
| the young reference is overwritten or removed | the owner stays remembered until the next minor collection, which scans it, finds nothing young and drops it. Conservative and correct; a little wasted work. |
| a minor collection | drains the list (pop, clear bit, scan, clear cards). The list ends empty. |
| a major collection | before marking, walks the list clearing bits and cards and empties it. Major marking traces everything, so it needs no remembered state. It frees `gray_next` for the gray list. |
| an owner is freed | can't happen while remembered: only old owners are remembered, a minor collection never frees old objects, and a major collection empties the list first. The verifier checks it. |

**Why `gray_next` is safe to reuse:**

- Between collections the gray list is empty (an existing assertion).
- During a minor collection only young objects are grayed, and a young object is never on the
  remembered list. Each owner is popped before its children are pushed.
- During a major collection the list is emptied before marking starts.

**The barrier** is in the existing store API, so there are no new store sites:

```zig
inline fn barrier(h, owner, old, new) void {
    if (!owner.old or !isYoungRef(new)) return;
    if (!owner.remembered) { owner.remembered = true; owner.gray_next = h.remembered; h.remembered = owner; }
}
// element stores additionally: if (cards) |c| c.set(index / card_elements);
```

It never allocates and never fails (D9).

### Element cards (point 3)

- **What gets cards:** an array whose element capacity reaches `card_elements` (512, in
  `limits.zig`). Its card bitmap has one bit per 512 elements, so a 1M array needs 2048 bits
  (256 bytes).
- **Where the bitmap is allocated:** it grows with the elements buffer, inside
  `appendElement(s)`, which already allocate and return `Error`. It is charged through the
  counting allocator, so accounting stays exact.
- **The store paths:**
  - `storeElement` is infallible and only writes an index below the length, so its card already
    exists;
  - `shrinkElements` and `popElement` need nothing: a minor collection clamps dirty cards to the
    current length.
- **Scan cost:** dirty cards × 512 elements. One young store into a 1M array costs about 512
  child checks (about 2 µs), not 4.4 ms.
- **Worst case:** every card is dirty because a frame overwrote the whole array. That is a full
  rescan, but then the frame also made that many young objects, so the work is proportional to the
  mutation.
- Smaller arrays are scanned whole. The 100k measurement (0.09 ms) suggests that's fine; 512 is
  the starting point, and P2's sweep can move it.
- **Known gap, not solved in P1:** P1 covers arrays' elements only. It does not claim that every
  large container is handled. Dictionary-like objects with huge *property* tables have the
  same problem, because their entries are scanned whole. Entry-index cards would be the same
  mechanism. P2 adds a `game_big_dictionary.js` workload to measure it before deciding.

**Card lifecycle:**

| event | effect |
|---|---|
| capacity first reaches 512 | allocate the bitmap. **If the array is already remembered, every card starts dirty.** |
| capacity grows past the bitmap | resize the bitmap. Existing bits are kept and new bits are zero. |
| a young value is stored or appended into an old carded array | the barrier sets bit `index / 512` and remembers the owner |
| a minor collection drains the owner | for each dirty card: scan its elements first, then clear its bit |
| a major collection | clears every bitmap of every remembered owner |
| pop or shrink | nothing changes. Dirty cards past the length are clamped by the scan and cleared with the rest. |

**Why the bold rule matters (the hole):**

1. An old array of 400 elements stores a young value at index 3. It has no bitmap yet, so it is
   remembered whole.
2. Appends then grow it past 512. A clean bitmap gets created.
3. The next minor collection scans only dirty cards, so it never looks at index 3. The young
   object is freed while the array still points to it.

Starting every card dirty makes that first scan whole, exactly what the remembered bit had
promised.

**Failure safety:** the bitmap is resized *before* the elements buffer. If the bitmap allocation
fails, nothing has changed. If the elements allocation fails afterwards, a bitmap that is already
large enough is harmless.

**Measuring it separately:** `Sample` gains `remembered_ns` (timed by the observer's clock around
step 1) and `remembered_children` (deterministic: the number of children checked). The report
shows both for minor collections.

### Weak atoms (point 5, and the review's correctness question)

Today's atom-table rebuild walks the whole object list, which is O(heap). A minor collection
mustn't do that. So the table is pruned only by major collections, which raises the review's
question: what keeps the table from holding a pointer that a minor collection freed?

**The answer: a minor collection never frees an atom.** The table can only point at objects that
a minor collection cannot free. The rule takes two existing facts and one new one:

1. The table holds only strings whose `atom` field is set. This is M8's
   `AtomTableHoldsNonAtom` check, unchanged.
2. A minor collection frees only young objects, and never a string whose `atom` field is set.
   When the sweep meets an unmarked young atom, it promotes it instead of freeing it.
3. Only a major collection frees atoms, and it rebuilds the table from the marked atoms *before*
   it sweeps, exactly as M8 does today.

So no atom is ever freed while the table still points at it.

**Checks:**

- The verifier's existing `AtomTableHoldsCollectedObject` check runs after every minor
  collection too, under stress.
- With tombstones, a freed atom left in the table is a deterministic failure, not a read of freed
  memory.
- **Mutation test:** let the minor sweep free unmarked atoms. A stress run of a dynamic-key
  program must then fail `AtomTableHoldsCollectedObject`.
- **Behaviour test:**
  1. intern a dynamic key on an object that dies;
  2. run a minor collection;
  3. intern the same text again: it must return the same (promoted) atom;
  4. run a major collection with no references left;
  5. the atom is gone and the table no longer holds it.

**What this costs:**

- **In a minor collection, atoms are strong.** A young atom always survives and is promoted. The
  sweep already holds each young object, so this costs O(nursery) and never touches the table.
- **In a major collection,** the table is rebuilt from the marked atoms, as now.
- **What this costs:** atoms of dead dynamic keys (`obj['k' + i]`) stay alive until the next major
  collection.
- **Why that can't run away:** promoted atoms are old objects, counted in `bytes` after the minor
  collection that promotes them, and the table's own buckets are charged through the counting
  allocator. Atom growth therefore drives the
  major-collection schedule like any other promotion. A test checks it: a loop creating a million
  dynamic keys on objects that die young must trigger major collections and stay under a small
  heap limit.

### Scheduling (point 4)

**Minor collection:** triggered when the bytes allocated since the last collection reach
`nursery_bytes` (`limits.zig`). That's `allocated − allocated_at_last_gc`; both counters
already exist. Allocation
only *requests* a collection, which runs at the next safepoint, as now. The starting value is
1 MiB, and P2 picks the final one from 256K/1M/4M runs.

**Major collection:** triggered at a safepoint by the first of:

1. After a minor collection, `bytes` ≥ `next_major`, where
   `next_major = schedule(bytes after the last major)`. After any collection everything is old,
   so `bytes` *is* the old generation. No new split accounting is needed. It's
   today's formula, with growth room of min(max(live, 256 KiB), (limit − live)/2), but it is now
   fed only by *promotion*. Garbage that dies young never reaches it, which is what removes M8's
   accumulate-then-hitch behaviour.
2. Heap pressure: an allocation that would exceed the limit gets a major collection and a retry
   before it reports `LimitExceeded`, as in M8 (I7).
3. Atom growth, which is covered by (1), because promoted atoms and the table's buckets are in
   `bytes` (see above). No
   separate trigger is needed.

**If both are due**, run only the major collection: it subsumes the minor one, and promotes every
survivor.

**Accounting:** unchanged. `bytes` stays the exact total, and the M8 verifier rule still holds
(Σ fixed charges over both lists + `buffer_bytes`). Allocation that grows an old object's buffer
counts toward the minor trigger too. That's correct: it is allocation pressure.

### Major collection

It's today's collector over both lists:

1. empty the remembered set and the cards;
2. mark everything;
3. rebuild the atom table;
4. sweep both lists, with every survivor going to `old`.

**Its pause is unchanged from M8. Making it shorter is M8.2's job (incremental marking).** M8.1
only makes major collections rare. The report states this rather than hiding it.

### Verification (reuses the M8 infrastructure)

**Verifier, new invariants:**

- **I-gen1:** every object on `young` is young, and every object on `old` is old.
- **I-gen2:** every old object with a young child is `remembered`. For a carded array, the card
  covering that element is also dirty. This is the check that catches a missing barrier, at the
  next verification after the bad store.
- **I-gen3:** after a collection, `young`, the remembered list and every card are empty.
- **I-gen4:** the remembered list is well formed:
  - its length equals the number of objects with `remembered` set (counted over both lists), so
    any duplicate or cycle is caught;
  - the walk is bounded by that count, so a corrupted cycle can't hang the verifier;
  - every listed object is old and live.
- **Exact accounting:** unchanged from M8, summed over both lists.

**Running it:**

- The verifier also runs *before* a minor collection's mark under stress, because I-gen2 is about
  the state the barrier built.
- `-Dgc-stress` runs a minor collection at every safepoint, a major collection every 64th time,
  and verification each time. Tombstones are unchanged, and CI keeps running it.

**Mutation tests**, each one must make a stress run fail:

- delete the `storeElement` barrier: fails I-gen2;
- delete the card set: fails I-gen2 on a carded array;
- skip clearing `remembered`: fails I-gen3 or I-gen4;
- create the bitmap clean for a remembered array: fails I-gen2 (the hole above);
- let the minor sweep free atoms: fails `AtomTableHoldsCollectedObject`.

**Card tests** (gc-stress and normal builds):

- In an old 2048-element array, store young objects at indices 0, 511, 512, 1023, 1024 and
  2047, one test each and then all together. After a minor collection each one is alive and
  reachable, and every other card was never scanned (checked through `remembered_children`).
- The hole case: remember at 400 elements, grow to 600, run a minor collection; the young value
  survives.
- Bitmap growth: grow a dirty-carded array through several resizes. Dirty bits survive and new
  bits are clean.
- Pop or shrink after a store: the minor collection is correct and the cards end clean.
- Allocation failure (`checkAllAllocationFailures`) on appends that grow the bitmap.

**Unchanged and still passing:** step counts and `zig build bench` rows, node outputs, and every
M8 GC test. Collection counts change, so the exact-stats tests get updated explicitly for minor
and major collections, not weakened.

### Implementation review checks (from the plan's approval)

1. **Promotion is not reachability.** An unmarked young atom is relinked and gets its `old` bit,
   but it is never marked or scanned. Strings have no children (`forEachChild` returns at once),
   so promoting one can't retain anything else. A test checks it: a dead object keyed by a dead
   dynamic atom is still freed by the same minor collection.
2. **Card allocation failure.** The bitmap grows first, then the elements buffer. If the
   elements allocation then fails, the array has its old elements and a larger, valid bitmap
   whose extra bits are clean. `checkAllAllocationFailures` covers it, followed by the verifier
   on every failed run.
3. **Major collection.**
   - The atom table is rebuilt *before* any atom is freed.
   - Remembered bits and cards are cleared before marking, so nothing stale survives.
   - Both lists are swept, and every survivor ends up old.
   - A test runs a major collection with dirty cards and remembered owners present, then checks
     I-gen3 and the atom invariant.

### Benchmark methodology

`gc-report` changes *before* P1 starts, and the M8 baseline is taken again with it. That way M8
and M8.1 are measured the same way.

- **5 runs per (workload, engine).** The steps and collection counts must be identical across
  runs, as `bench` already checks.
- **Statistics:** the median across runs of each run's p50, p95 and max pause, plus the spread
  (min to max) of those values across the runs. In this revision's baseline, game_100k's max
  pause was 24 ms in one run and 41 ms in another. One run can't settle a comparison.
- **Pause distribution,** all runs pooled, in buckets: under 0.1 ms, 0.1–1, 1–4, 4–16 and over
  16 ms.
- **Minor and major collections reported separately.** For minor collections, three numbers on
  separate lines: the remembered-set scan time (`remembered_ns`), the rest of the pause, and the
  total.
- **A comparison is valid only on the same machine, build mode and workload file.** The report
  header records the machine and build mode.

### Acceptance (M4, ReleaseFast, `zig build gc-report`, medians of 5 runs)

| metric | target |
|---|---|
| minor p95, every game workload | under 1 ms |
| game_100k vs game_1m minor pause | within 2× |
| game_growing minor-pause series | no upward trend |
| game_big_container `remembered_ns` per minor | under 0.1 ms (cards) |
| game_1m frame loop | collects; memory stays bounded |
| GC share and pauses > 16 ms | lower than M8 on all game workloads, shown side by side in `bench/gc/` |
| major pauses | reported honestly; their length is unchanged, only their count |

### Phases

- **P0 (before P1):** the methodology above, and the M8 baseline taken again with it.
- **P1:** the header bits, the two lists, minor collection, the barrier, the remembered list, element
  cards, the I-gen invariants, stress with minor and major collections, and the mutation tests.
- **P2:** scheduling (`nursery_bytes`, `next_major`, the atom-growth test), observer kinds plus
  `remembered_ns`, the gc-report minor/major split, the nursery and card size sweep, and
  `game_big_dictionary.js`.
- **P3:** the M8 → M8.1 comparison, and docs: GC_DESIGN §7 and §13 (the order is now generational
  in M8.1, then incremental in M8.2), new D-entries, and ROADMAP.

### P2 results (measured, M4, ReleaseFast, `gc-report`, 5 runs per row)

**Nursery size** (game workloads, VM; the small programs agree):

| nursery | minor p95 (game_100k / game_1m) | GC share (game_100k / game_1m) | peak memory overhead | majors (game_1m) |
|---|---|---|---|---|
| 256 KiB | 0.064 / 0.062 ms | 17.7% / 25.4% | +0.25 MB | 9 |
| 512 KiB | 0.136 / 0.139 ms | 17.7% / 26.6% | +0.5 MB | 8 |
| 1 MiB | 0.319 / 0.289 ms | 17.7% / 27.3% | +1 MB | 7 |
| 2 MiB | 0.620 / 0.579 ms | 17.5% / 34.5% | +2 MB | 7 |
| 4 MiB | 1.279 / 1.090 ms | 18.5% / 36.4% | +4 MB | 6 |

- **Pause and memory grow with the nursery.** A minor collection is almost all sweep of
  garbage, so the pause is proportional to the nursery size, and so is the peak overhead.
- **Total GC time doesn't fall with a bigger nursery.** The sweep's total work follows the
  garbage, not the collection count. Past about 1 MiB it gets *worse*, because a nursery that
  outgrows the cache sweeps slower.
- **What a bigger nursery does buy** is less premature promotion: game_1m runs 9 majors at
  256K and 6 at 4M.
- **Default: 256 KiB** (`limits.zig`). That's also M8's first trigger, so small programs'
  peak memory is back to M8's.
- **Caveat for M9:** each minor collection marks the roots, including every constant of the
  running script, so a script with tens of thousands of constants pays that 4× more often
  than at 1 MiB.

**Profile of the sweep (before changing its structure): it's the allocator.**

zqjs links libc, so the runtime's default allocator is macOS `malloc`, and `free` is about 80%
of the sweep. The same runs on `std.heap.smp_allocator` (`gc-report -- --allocator=smp`), medians
of 3 rounds:

| | libc malloc | smp_allocator |
|---|---|---|
| game_100k VM: minor p50 | 0.061 ms | 0.011 ms |
| game_100k VM: GC share | 17.8% | 5.3% |
| game_growing tree-walker: GC share | 28% | 13% |
| sweep cost per freed object | ~38 ns | ~7 ns |

The young list itself is not the bottleneck. The allocator is the embedder's choice
(`Heap.init` takes one), so this belongs to M9's API and documentation, not to the collector.

**Minor-pause outliers (1–30 ms, rare): OS preemption.**

- A different collection is slow each run, and its work is normal.
- The whole stall lands inside one tiny object's release.
- One report run had 0 IO page faults, 0 swaps and 573 involuntary context switches.
- SmpAllocator, whose small frees make no syscalls, shows them too.

That's strong evidence, not proof. `malloc` returning memory to the kernel (`madvise`, seen
rarely in profiles) may add some.

**Large dictionary** (`game_big_dictionary.js`, 200k entries, one young store per frame):

- minor p95 1.9 ms, of which 1.85 ms is the remembered-set scan;
- the whole property table (keys and values) is rescanned at every minor collection;
- at 1M entries it would be about 10 ms.

This is the gap P1 left open, now measured: entry-index cards for property tables are the
candidate fix (decision pending).

**Major collections: all of them happen while live data grows.**

- In every game workload the majors fall at each doubling of the live heap during setup
  (0.5, 1.5, 3.3 … 240 MB).
- The frame loops run no major collection at all.
- The long pauses (60–90 ms at 1M) are the last doubling.

Options: grow faster when a major frees almost nothing (fewer majors during growth; that
changes D8's formula, decision pending), and M8.2's incremental marking for the pauses
themselves.

**Atom growth:** a test runs 60k dead dynamic keys in a 1 MiB heap. Major collections free
them and the run fits. With the growth trigger disabled it fails with `LimitExceeded`.

### P2b design: property-table cards and adaptive major scheduling (for review)

- **Property-table cards:** approved with the additions below (PC6–PC8).
- **Adaptive scheduling:** revised for review, with `f_max = 4` (the reviewer's choice).

#### Property-table cards

**Storage.** A property table is an `AutoArrayHashMapUnmanaged(*String, Property)`. Its entries
sit in insertion order at stable indices (`keys()[i]`, `values()[i]`), and the hash index on
top doesn't affect them. A card covers 512 *entries*: entry i's key and value share card
`i / 512`.

The bitmaps live in a second side table, `prop_cards`, next to the elements' `cards`. An array
can have both; they share the bit-twiddling helpers and nothing else, because the layouts
differ. Elements are a plain slice indexed by element. Property entries are indexed by
insertion and can shift on delete.

**Invariants:**

- **PC1 (I-gen2 extended).** An old object whose table has a bitmap, and a young key or value
  at entry i, is remembered *and* has property card `i / 512` dirty. The verifier checks it.
  A table without a bitmap is remembered whole, as today.
- **PC2: index shifts.** Entry indices change only through `orderedRemove` (`delete o[k]`),
  which moves every later entry down one place. On removal from a carded table, every card
  from the removed entry's card to the last one is dirtied. That's because a young entry
  just past a card boundary can move into a clean card, for example from 1024 (card 2) to
  1023 (card 1). Nothing else changes indices: growing or rehashing the index doesn't, and
  replacing an existing key keeps its index.
- **PC3: coverage, and the hole rule.** A table gets a bitmap before the insertion that takes
  it to 512 entries, and the bitmap is grown before any insertion it wouldn't cover.
  - **Growth:** coverage grows geometrically, independently of the hash map's capacity.
  - **The hole rule:** a first bitmap for an owner that is already remembered starts all
    dirty, the same rule as for arrays.
  - **Allocation order:** the bitmap grows *before* the table grows. If the bitmap can't
    grow, nothing has changed. If the table's `getOrPut` then fails, a larger bitmap is
    harmless.
- **PC4 (I-gen3 extended).** After any collection, every property card is clean.
- **PC5: lifetime.** A table's bitmap is freed with its object, in `release`. `deinit`
  asserts that `prop_cards` is empty.
- **PC6: every store dirties its own card.** Every store of a young reference into an old
  carded table dirties the card of that entry's index:
  - a new key appended at index `count` (the key, the value, or both may be young);
  - a value updated under an existing key, at that key's unchanged index.

  All of it goes through `storeProperty` and `defineProperty`, which know the index.
- **PC7: reallocation.** When the entries buffer grows and moves, the indices stay valid,
  because a card names an entry index, never an address. A test grows a dirty table through
  many reallocations, to 40k entries.
- **PC8: the verifier checks the edges, not the bitmap.** For every old object with a bitmap,
  it walks every entry. For each young key or value it finds, the covering card must be
  dirty. It never takes the bitmap's word for which entries matter. Clamped dirty cards past
  the count are allowed. Clean cards over young entries are not.

  The delete rule (PC2) dirties cards only for an owner that is already remembered. An owner
  that isn't remembered has no young children (I-gen2), so nothing can shift into a clean
  card. Leaving its cards untouched also keeps I-gen3 (no dirty card after a collection),
  because collections only clear the cards of remembered owners.

**Scanning a remembered owner:**

1. its prototype;
2. its properties: the dirty property cards if the table has a bitmap, every entry if not;
3. its elements: the dirty element cards, or all of them.

Dirty cards past the current count are clamped. Each card is scanned, then cleared. A
missing bitmap falls back to a whole scan, which is always safe.

**Tests**, under normal and stress builds:
- young stores at entries 0, 511, 512, 1023, 1024 and the last;
- a young *key* with an old value;
- the delete shift across a card boundary;
- the hole: remembered at 400 entries, grown to 600;
- growth to 40k entries;
- deletes at the beginning, middle and end, with several young entries shifting across card
  boundaries at once;
- `checkAllAllocationFailures` on inserts that grow the bitmap;
- the bitmap dying in a minor collection and in a major one.

**Mutants** (`gc-mutants`): `no_prop_card_set`, `no_dirty_on_remove` and
`clean_first_prop_bitmap`. Each must fail PC1.

**Acceptance:** game_big_dictionary's minor p95 under 1 ms, and its remembered-set p95 under
0.1 ms (1.9 and 1.85 ms today).

#### Adaptive major scheduling (revision 2, for review)

Today `next_major = live + min(max(live, 256 KiB), (max − live)/2)`, which is D8's formula. It
grows the heap by 1× live, whatever the last major collection found.

**Definitions.** At each major collection:

- `before` = `h.bytes` when the major collection starts. That's the whole heap, old and young
  (the young part is at most one nursery).
- `after` = `h.bytes` when it ends. Every survivor is old by then, so this is `live`.
- `r = (before − after) / before`: the fraction of the heap that collection freed. It's
  computed in integers as `freed · 10 < before` and `freed · 2 ≥ before`, so no division or
  float is involved and it's deterministic.

**The rule.** A growth factor `f ∈ {1, 2, 4}`, so `f_max = 4`. It starts at 1 and changes only
at a major collection:

| that major freed | new `f` |
|---|---|
| under 10% (`freed · 10 < before`) | `min(2f, 4)` |
| at least 50% (`freed · 2 ≥ before`) | 1 |
| anything in between | unchanged |

`next_major = live + min(max(f · live, 256 KiB), (max − live)/c(f))`, with `f · live`
saturating, `c(1) = 2` (D8 today) and `c(2) = c(4) = 4`: the quarter-room cap, from the burst
analysis below (AS5).

**The hard limit (AS1), argued from the code as it stands.** Write `L` for `max_heap_bytes`.

1. **No allocation ever goes past `L`.** `reserve` refuses any charge that would take `bytes`
   over `L`, so `bytes ≤ L` holds at every moment, under any schedule. Scheduling decides
   only *when* collections happen.
2. **The major threshold stays below `L`.** For any `f`, `next_major ≤ live + (L − live)/2`,
   which is strictly less than `L` while `live < L`.
3. **A collection is requested at least every half of the remaining room.** After every
   collection, `next_gc = bytes + min(nursery, (L − bytes)/2)`. Once `bytes` passes
   `next_gc`, the next safepoint collects. So while the heap fills, collections come at
   distances that halve.
4. **A major collection comes before the heap is full.** The old size after a collection
   increases only through promotion, and by (3) collections keep happening as `bytes`
   approaches `L`. So the old size reaches `next_major`, which is below `L` by (2), before
   `bytes` can reach `L`. The next collection after that is a major one.

   Between "major due" and that next collection, the heap grows by at most half the room, so
   the major collection runs while the heap is still within the limit and can free the old
   garbage.
5. **What it does not prevent:** a single allocation bigger than the room left fails at once,
   because allocation never collects (D7). That's M8's behaviour too, and `f` doesn't change
   it.

`f` appears only inside the `min(…)` that (2) bounds, so all of the above holds at
`f = 1, 2, 4` alike.

**Bursts and the hard limit (AS5, revision 3: the proof asked for in the third review).**

**Definitions.**

| symbol | meaning |
|---|---|
| `L` | `max_heap_bytes` |
| `N` | `nursery_bytes` |
| `bytes` | the accounted heap at a given moment |
| `R` | reachable bytes: what a full mark would keep |
| `B` | the heap after the last collection of any kind (all of it old) |
| `live` | the heap after the last major collection |
| `P` | what one minor collection promotes |

A *burst* is all the allocation between two safepoints. Nothing collects inside it (D7).

**The rule under review:**

- `growth(f, live) = min(max(f · live, 256 KiB), (L − live) / c(f))`, with `c(1) = 2` (D8 as it is
  today) and `c(2) = c(4) = 4` (the quarter-room cap);
- `next_major = live + growth`;
- after every collection, `next_gc = B + min(N, (L − B)/2)`;
- a collection is major iff, when it starts, `B ≥ next_major` (or a major one was requested).

"The hard-limit guarantee" covers three separate statements.

**HL1: the limit is never exceeded.** `bytes ≤ L` at every moment, for every program and every
`f`. `reserve` refuses any charge that would take `bytes` past `L`, before allocating. That
doesn't depend on scheduling at all.

**HL2: a burst within the bound never fails.** A burst of total size `S` succeeds whenever
`S ≤ (L − B)/2`, where `B` is the heap left by the last collection before it. This holds for
every `f`.

*Proof:*
- At the safepoint before the burst, a pending collection runs first and resets `B` and
  `next_gc`.
- With none pending, `bytes ≤ next_gc ≤ B + (L − B)/2`, so the free room is at least
  `(L − B)/2 ≥ S`.
- During the burst only allocation happens, so the burst fits.
- `f` appears nowhere in this.

**What `f` does to that bound.** How big `(L − B)/2` can be depends on how far `B` gets from
`live`.

*Lemma: `B < next_major + P`.*
- `B` only grows at a minor collection, by that collection's promotion.
- A collection is minor only if the `B` before it was below `next_major`.

*So the guaranteed burst room is*
`(L − B)/2 > (L − live − growth − P)/2 ≥ (L − live)(1 − 1/c(f))/2 − P/2`:

| `f` | `c(f)` | worst-case burst room |
|---|---|---|
| 1 | 2 | `(L − live)/4 − P/2`: D8's guarantee today |
| 2, 4 | 4 | `3(L − live)/8 − P/2`, which is more |

So **with the quarter-room cap, no supported `f` has a smaller worst-case burst room than
today's rule.** Revision 2 (no cap) only matched it, and was worse in the typical case.

**Bursts whose results survive.** A surviving burst of size `S` is reachable data.
- The next safepoint's collection promotes it, so it's part of `P`.
- It raises `B` and `R` alike. The next burst's room shrinks because live data grew, not
  because of garbage.
- The old garbage that schedule decisions can leave is `B − R ≤ growth + D`. Here `D` is
  promoted-but-dead data: floating garbage, and dead atoms (minor collections never free
  atoms).
- `D` is cleared by the next major collection, and `growth` is the capped term above.

**HL3: a failure is legitimate when the data truly doesn't fit.** If `R + S > L`, the burst fails
under any scheduler and any `f`: `bytes ≥ R` always, and `reserve` refuses. It reports
`LimitExceeded(heap_bytes)`.

**The gap, stated honestly.** When `R + S ≤ L` but `S > (L − B)/2`, a burst *may* fail. That's
the cost of an allocator that never collects (D7): it exists in M8 and under D8 today. The
adaptive rule doesn't widen its worst case (HL2's table). It narrows the typical headroom far
from the limit by at most `growth − live` (at most `3·live` at `f = 4`), and the quarter cap
keeps even that within a quarter of the room.

**Tests:**

- **T1: a grid of the formulas** (unit).
  - Inputs: `L ∈ {256 KiB, 1 MiB, 64 MiB, maxInt}`, `live ∈ {0, 1, L/8, L/2, L − 1, L}`,
    `B ∈ [live, L]` at the same points, `f ∈ {1, 2, 4}`.
  - Checks: `growth ≤ (L − live)/c(f)`, `next_major ≤ L`, `next_gc ≤ B + (L − B)/2`, and no
    overflow (saturating `f · live`).
- **T2: a burst simulator on the heap API** (unit, fast, no engine).
  - **Setup:** a mutator loop. Its "safepoints" collect whenever `collect_requested`, and its
    roots are a test root set. It runs with `f` pinned at 1, 2 and 4, and once adaptive.
  - **Phase A:** grow reachable data to about 40% of `L` while churning short-lived garbage,
    plus *old* garbage: objects kept for one collection, then dropped.
  - **Phase B (HL2), at hundreds of positions between collections:** a burst of exactly
    `S = (L − B)/2`.
    - Its result is kept on alternate bursts, so surviving bursts are covered.
    - Each one must succeed.
    - `bytes ≤ L` always (HL1).
  - **Phase C (HL3):**
    1. after a major collection gives the exact `R`, request `S = L − R + 1`;
    2. it must fail with `LimitExceeded(heap_bytes)`;
    3. `verify()` must pass afterwards;
    4. the next in-bound burst must succeed (the failure left the heap usable).
- **T3: programs, both engines, 1 MiB limit.**
  - (a) Bursts via `join`, sized within the bound at every phase, results kept on alternate
    iterations: the program completes.
  - (b) Surviving bursts that keep growing until `R + S > L`: the run ends with
    `LimitExceeded(heap_bytes)`. Before that, a major collection must have run, so nothing
    failed for lack of a major collection.
- **The existing O(log limit) fill test**, unchanged.

**What isn't promised:** that a burst with `(L − B)/2 < S ≤ L − R` succeeds. No test asserts it
either way, because the outcome depends on where between collections the burst lands.

**Overhead bound (AS3).** At the next major collection, old bytes are at most `(1 + 4) · live`,
and never more than `L`.

**Determinism and reset (AS2, AS4)** are as before: `f` comes from byte counts only, and one
major collection that frees at least half resets it to 1.

**What it buys** (simulated on game_1m's growth curve, `f_max = 4`):
- major collections at about 0.5, 1.5, 7.5, 37.5 and 187 MB: five instead of nine;
- the last one at 187 MB instead of 240 MB.

That gain is in collection count. Pause length is M8.2's job.

**Tests:**

- **The adaptation cycle** (unit, `h.growth` exposed for the test):
  1. live data that survives;
  2. three major collections that each free under 10%: `f` goes 1 → 2 → 4 → 4 (the cap);
  3. drop most of it, run a major collection that frees over 50%: `f` = 1;
  4. one that frees 30%: `f` unchanged.
- **The extremes:** `schedule(live)` for every `f`, `live ∈ {0, 1, L/2, L−1, L}` and
  `L ∈ {0, 1, 100, 1 MiB, maxInt}`: never above `L` (and never below `live`), no overflow.
- **A nearly full heap with continuous allocation:** a 1 MiB heap. Live data grows to about
  70%. Then a churn loop runs for a long time, allocating objects that survive a minor
  collection and then die *old* (a ring buffer that keeps replacing its oldest entries).
  - It must finish without `LimitExceeded`, with major collections > 0 and `peak ≤ 1 MiB`.
  - It runs on both engines, after the growth phase has pushed `f` to 4.
- **The existing O(log limit) fill test** keeps passing unchanged.

These are scheduling properties, so they're unit tests, not verifier mutants: the heap stays
sound under any `f`, only its timing changes.

**Decisions:** this replaces D8's formula, so D8 gets a revision entry in P3's docs.

### Out of scope

- Incremental marking (M8.2).
- Property-entry cards: P2 measures the need, and they get built only if the measurement asks
  for them.
- Age counters and size-class pages.
- Moving or compaction.

### M9 note

The embedding API must store through the same store API, because a raw host store would skip the
barrier and fail I-gen2 under stress. That's the I3 rule again, so M9 extends the source scan to
the C-ABI file.
