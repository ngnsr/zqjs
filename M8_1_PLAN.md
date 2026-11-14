# M8.1 plan: generational collection (non-moving)

Status: **revision 3, for review.** Revision 2 answered the five review points and added element
cards, which a measurement showed are needed. Revision 3:
- states the weak-atom safety rule explicitly;
- fixes a card-creation hole found while writing the card lifecycle;
- adds card boundary tests;
- fixes the benchmark methodology. Nothing below is implemented yet.

- Baseline: `bench/gc/baseline-m8.txt` (`zig build gc-report`, M4, ReleaseFast).
- All targets below are for that machine, not universal guarantees.

## What the baseline says

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

## Generations

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

## Minor collection

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

## Remembered set (point 2)

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

## Element cards (point 3)

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

## Weak atoms (point 5, and the review's correctness question)

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

## Scheduling (point 4)

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

## Major collection

It's today's collector over both lists:

1. empty the remembered set and the cards;
2. mark everything;
3. rebuild the atom table;
4. sweep both lists, with every survivor going to `old`.

**Its pause is unchanged from M8. Making it shorter is M8.2's job (incremental marking).** M8.1
only makes major collections rare. The report states this rather than hiding it.

## Verification (reuses the M8 infrastructure)

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

## Benchmark methodology

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

## Acceptance (M4, ReleaseFast, `zig build gc-report`, medians of 5 runs)

| metric | target |
|---|---|
| minor p95, every game workload | under 1 ms |
| game_100k vs game_1m minor pause | within 2× |
| game_growing minor-pause series | no upward trend |
| game_big_container `remembered_ns` per minor | under 0.1 ms (cards) |
| game_1m frame loop | collects; memory stays bounded |
| GC share and pauses > 16 ms | lower than M8 on all game workloads, shown side by side in `bench/gc/` |
| major pauses | reported honestly; their length is unchanged, only their count |

## Phases

- **P0 (before P1):** the methodology above, and the M8 baseline taken again with it.
- **P1:** the header bits, the two lists, minor collection, the barrier, the remembered list, element
  cards, the I-gen invariants, stress with minor and major collections, and the mutation tests.
- **P2:** scheduling (`nursery_bytes`, `next_major`, the atom-growth test), observer kinds plus
  `remembered_ns`, the gc-report minor/major split, the nursery and card size sweep, and
  `game_big_dictionary.js`.
- **P3:** the M8 → M8.1 comparison, and docs: GC_DESIGN §7 and §13 (the order is now generational
  in M8.1, then incremental in M8.2), new D-entries, and ROADMAP.

## Out of scope

- Incremental marking (M8.2).
- Property-entry cards: P2 measures the need, and they get built only if the measurement asks
  for them.
- Age counters and size-class pages.
- Moving or compaction.

## M9 note

The embedding API must store through the same store API, because a raw host store would skip the
barrier and fail I-gen2 under stress. That's the I3 rule again, so M9 extends the source scan to
the C-ABI file.
