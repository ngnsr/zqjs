# M8.1 plan: generational collection (non-moving)

Status: **proposal, for review.** Nothing below is implemented. Baseline: `bench/gc/baseline-m8.txt`
(`zig build gc-report`, M4, ReleaseFast).

## What the baseline says

| workload (VM) | live after GC | max pause | GC share | pauses > 16 ms |
|---|---|---|---|---|
| game_100k | 43 MB | 24 ms | 28% | 7 |
| game_growing (to 300k) | 111 MB | 73 ms | 35% | 5 |
| game_1m | 426 MB | 308 ms | 58% | 4 |

Two things matter for the design:

1. **Every pause traces the whole live heap.** game_growing's per-collection series grows linearly:
   about 0.14 µs per live object, whether the objects changed or not. In game_100k each steady-state
   collection marks the 200k persistent objects to free about 290k temporaries that died a frame
   after they were made.
2. **The heap-doubling schedule hides the cost by deferring it.** In game_1m the frame loop never
   collects at all: after setup `next_gc` is about 850 MB, so the 120 MB of per-frame garbage just
   piles up. That costs memory now and one 300 ms hitch later. A nursery collected often fixes the
   memory side too.

## Design

**Generations.** Each object header gets an `old` bit. It fits in padding next to `marked`, so the
header doesn't grow. The heap keeps two intrusive lists instead of one:

- `young`: the nursery. Every new object goes here.
- `old`: promoted objects.

Nothing moves. Promotion moves an object from one list to the other and sets its bit. Addresses stay
fixed, as D8 requires (natives, and in M9 the C ABI, hold raw pointers).

**Minor collection.** Stop-the-world, at the same safepoints as today.

- **Marking.**
  - Mark from the engine roots plus the remembered set.
  - `markObj` returns immediately on an old object, so old objects are never traversed.
  - The cost is O(roots + remembered set + young survivors).
- **Sweep.** Walk only `young`:
  - unmarked objects are freed, or tombstoned under stress;
  - marked objects are unmarked, set `old`, and moved to `old`.
- **Promotion policy: promote on the first survival.** At a safepoint the live temporaries are
  tiny (a frame's `v` and `label`), so premature promotion costs little. In exchange:
  - no age counter;
  - **the nursery is empty after every minor collection**, so the remembered set can be cleared
    too and no old→young edge survives a minor collection;
  - that invariant is easy to state and to verify.

  An age counter (survive 2) is a measured follow-up. It would only matter if the report shows
  promoted garbage driving up the major-collection rate.

**Remembered set and write barrier.** The M8 store API already passes `(owner, old, new)` at
every reference store. The barrier becomes:

```zig
if (owner.old and !owner.remembered and isYoung(new)) { owner.remembered = true; push(owner); }
```

- The set is intrusive. It reuses `gray_next`, which is free between collections, so the barrier
  never allocates and never fails. A store can't fail on account of the barrier (D9: no
  allocation in the GC paths).
- A minor collection drains it first: each remembered owner's children are marked, then its
  `remembered` bit is cleared.
- Granularity is per object, not card marking. The 1M-element `entities` array storing one young
  element would rescan the whole array. Cards are a follow-up only if the report shows it.
  game_* stores numbers into old objects, so its remembered set stays empty.

**Not barriered, and no need:**

- Young owners.
- Stores of non-references (numbers, booleans).
- Young→old edges.
- Roots (VM stack, locals, the tree-walker's shadow stack). They are scanned at every minor
  collection, as now.
- Construction-time fields such as a closure's captures and an object's prototype. The new object
  is young, so no barrier is needed.

**Weak atoms (D11).** Today's table rebuild walks the whole object list, which is O(heap) and
would make every minor collection O(heap) again. Instead:

- In a minor collection, atoms are strong: a young atom always survives and is promoted. The
  sweep sees that it's an atom, which is O(nursery), with no table scan.
- The table is rebuilt only at a major collection, as now.
- Trade-off: atoms of dead dynamic keys (`obj['k' + i]`) live until the next major collection.

**Major collection.** Exactly today's collector over both lists:

1. Discard the remembered set.
2. Mark everything.
3. Rebuild the atom table.
4. Sweep both lists; every survivor goes to `old`.

**Its pause is unchanged from M8. That is M8.2's job (incremental marking).** M8.1 only makes
major collections rare.

**Scheduling.**

- **Minor:** when nursery bytes reach `nursery_bytes`. It goes in `limits.zig`; the proposed
  default is 1 MiB, to be picked from 256K/1M/4M runs in the report.
- **Major:** the existing `schedule()` formula, applied to old bytes after the last major
  collection and checked when promotion grows `old`.
- **Heap limit:** before giving up, run a major collection, as today.
- **Accounting:** `bytes` stays the total. `young_bytes` is added beside it.

**Observer.** `Sample` gains `kind: enum { minor, major }` and `promoted`. The report then splits
minor and major statistics.

## Verification (reuses the M8 infrastructure)

- **Verifier, new invariants.**
  - **I-gen1:** every object on `young` is young; every object on `old` is old.
  - **I-gen2:** every old object with a young child is `remembered`.
    - This is the important one: a missing barrier fails here deterministically, at the next
      verification after the bad store.
    - It runs after every collection under stress, and before each minor collection's mark.
  - **I-gen3:** after a minor collection, `young` and the remembered set are empty.
- **`-Dgc-stress`.** A minor collection at every safepoint, a major collection every 64th time,
  and verification each time. Tombstones are unchanged. CI keeps running it.
- **Mutation test.** Delete one barrier (`storeElement`). A stress run of a test that stores a
  young value into an old array must then fail I-gen2.
- **Unchanged and still passing:** step counts and `zig build bench` rows, node outputs, every M8
  GC test. Collection counts change; the exact-stats tests get updated for minor vs major
  explicitly, not weakened.

## Acceptance

- Minor pauses: game_100k and game_1m p95 within 2× of each other, and under 1 ms. This is the
  "stays flat as the old generation grows" check.
- game_growing's minor-pause series is flat: no trend across the run.
- GC share and >16 ms pause counts go down on all three game workloads. M8 and M8.1 appear side by
  side in `bench/gc/`.
- game_1m's frame loop collects, so memory stays bounded instead of piling up to `next_gc`.
- Major pauses are reported honestly. Their length is unchanged, only their count.

## Phases

- **P1.** Header bit, two lists, minor collection, barrier, the I-gen invariants in the verifier,
  stress mode with minor and major.
- **P2.** Scheduling (`nursery_bytes`), observer kinds, the gc-report minor/major split, the
  nursery-size sweep.
- **P3.** M8 → M8.1 comparison, docs: GC_DESIGN §7/§13 (the order is now generational, then
  incremental), new D-entries, ROADMAP.

## Out of scope

- Incremental marking (M8.2).
- Card marking, age counters, size-class pages. Each waits for a measurement that asks for it.
- Moving or compaction.

## M9 note

The embedding API must store through the same store API; a raw host store would skip the barrier.
That's the same rule I3 already enforces internally, so M9 just extends the source scan to the
C-ABI file.
