# Performance & Optimization Plan

This document records the post-M10 performance roadmap for ZQJS: what we already achieved, how to reach and surpass QuickJS as a **pure, portable interpreter**, and why a JIT is intentionally deferred.

---

## 1. Where We Stand

At the M10 checkpoint (`05c0c7a`, see `ROADMAP.md` and `bench/suite/baseline-qjs.md`), ZQJS's stack VM — **without** NaN-boxing, hidden classes, inline caches, or threaded dispatch — measured:

- **Closures (`closures.js`):** `0.75×` QuickJS (faster than QuickJS)
- **Objects, fib, loops, arrays, calls:** `1.66×–2.33×` QuickJS
- **C-ABI throughput:** `~6.59M calls/s` (`js_to_c_native`), `~4.87M trips/s` (`host_js_c_js_roundtrip`), `18.0 µs` p50 per frame on `frame_loop_3600`

### M52–M68 Checkpoints (D82–D89 + Slab Pools & VM Register Discipline — Geomean `0.73×` QuickJS!)

After M52–M59 (D82–D89), ZQJS reached QuickJS parity (`0.96×` geometric mean, game-loop GC peak RAM down **40–65%**, C-ABI `frame_loop_3600` p50 `18.0 µs → 11.0 µs`). Subsequent VM call/return, property-IC, fused arithmetic, shape-transition optimizations (M66: `0.74×`), inline small-string buffer (`bbeb42a`), `returnConstruct` without `*FrameCache` (`bb800dd`), unified `SlabPool` + intrusive freelists for `String`/`Object`/`Closure`/`Cell` (`5398f19`), and `noinline` guards on `fastTypedArrayGet/Set` + `Heap.newArray` (`238babd`, preventing `runLoopInner` `cache.sp` register spills) brought the **geometric mean across all 11 CLI benchmarks down to `0.73×` QuickJS (`0.7297×` exact)** (`0.38×–1.01×`, beating QuickJS on **10 of 11** workloads, cutting `strings.js` by **-29.4%** to `0.75×` QJS and speeding up all 5 `bench/gc/game_*.js` workloads by **-5.0% to -23.5%** — `game_big_dictionary.js` `262.2 → 200.7 ms`, `game_1m.js` `198.6 → 172.3 ms`; measured on AC power via `python3 tools/bench_compare.py`, Apple M4, Zig `0.17.1` `ReleaseFast`, QuickJS `2026-06-04`):

| Benchmark | Pre-M52 (`zqjs/qjs`) | M59 (`zqjs/qjs`) | M66 (`zqjs/qjs`) | **M68 (`zqjs/qjs`)** | ZQJS CLI med |
|---|---:|---:|---:|---:|---:|
| `closures.js` | `0.77×` (95.2 ms) | `0.50×` (60.7 ms) | `0.39×` | **`0.38×`** | **46.00 ms** (2.6× faster than QJS, -52%) |
| `branch_dense.js` | `1.91×` (200.8 ms) | `0.70×` (73.8 ms) | `0.58×` | **`0.58×`** | **59.96 ms** (42% faster than QJS, -70%) |
| `int_loop.js` | `2.07×` (141.9 ms) | `0.89×` (60.1 ms) | `0.62×` | **`0.62×`** | **42.12 ms** (38% faster than QJS, -70%) |
| `scopes.js` | `2.38×` (84.1 ms) | `1.04×` (36.4 ms) | `0.69×` | **`0.69×`** | **24.14 ms** (31% faster than QJS, -71%) |
| `float_math.js` | `2.14×` (286.7 ms) | `1.05×` (139.5 ms) | `0.70×` | **`0.71×`** | **94.78 ms** (29% faster than QJS, -67%) |
| `strings.js` | `2.31×` (26.3 ms) | `1.02×` (12.4 ms) | `1.01×` | **`0.75×`** | **8.62 ms** (25% faster than QJS, -67%) |
| `fib.js` | `1.90×` (64.3 ms) | `1.13×` (36.9 ms) | `0.78×` | **`0.80×`** | **26.34 ms** (20% faster than QJS, -59%) |
| `call_chain.js` | `2.37×` (122.0 ms) | `1.27×` (64.5 ms) | `0.93×` | **`0.91×`** | **45.79 ms** (9% faster than QJS, -62%) |
| `arrays.js` | `2.42×` (400.0 ms) | `0.94×` (155.6 ms) | `0.90×` | **`0.92×`** | **151.68 ms** (8% faster than QJS, -62%) |
| `global_reads.js` | `2.61×` (64.4 ms) | `1.19×` (28.7 ms) | `0.88×` | **`0.94×`** | **22.59 ms** (6% faster than QJS, -65%) |
| `objects.js` | `2.37×` (75.4 ms) | `1.19×` (38.0 ms) | `0.97×` | `1.01×` | **31.96 ms** (-58%) |
| **Geomean (11 CLI)** | `2.03×` | `0.96×` | `0.74×` | **`0.73×`** | **10/11 faster than QJS** |

*Note:* Labeled-switch threaded dispatch with `noinline` cold handlers, expanding `FrameCache` with `stack`/`locals` pointers, and removing `stack_limit` from `FrameCache` all regressed due to arm64 register spilling and I-cache bloat, and were reverted per §5. Conversely, keeping `returnConstruct`, `fastTypedArrayGet/Set`, and `Heap.newArray` `noinline` proved essential to keep `FrameCache.sp` promoted to a register inside `Vm.runLoopInner`.

QuickJS uses reference counting (inc/dec on every stack move), 16-byte `JSValue` on 64-bit platforms, and no inline caches. Because ZQJS already has a tracing generational GC (zero refcount traffic in hot loops) and isolated value/stack representations (D5, D12, D35, D36), matching and beating QuickJS as a pure interpreter is realistic without a rewrite.

---

## 2. Tier 1 — Localized Interpreter Speedups (Target: QuickJS Parity)

Low-risk, localized changes that preserve the current bytecode architecture, verifier, and dual-engine parity:

1. **8-byte NaN-boxed `Value` & `Vm.Slot` (D5, D85) — DONE (M55):**
   - Shrank `Value` from 16 bytes to 8 bytes (`packed struct(u64)`) inside `src/runtime/value.zig` and `Vm.Slot` from 24 bytes to 8 bytes (`packed struct(u64)`) inside `src/vm/vm.zig`.
   - Halved memory bandwidth for operand stacks, locals, cells, and dense arrays, and simplified GC marking/barrier checks to a single range check.
2. **Zig labeled-switch threaded dispatch:**
   - Use Zig's labeled `sw: switch (op) { ... continue :sw next_op; }` in `Vm.runLoop()` so LLVM emits per-opcode indirect jumps (computed goto) instead of a single central jump-table dispatch, improving CPU branch prediction.
3. **Back-edge & call-site budget/safepoint checks:**
   - Charge `rt.steps` in basic-block chunks and check `collect_requested` / step limits on backward jumps, calls, and allocations rather than on every straight-line instruction (keeping `Vm.step()` exact for single-stepping and `--trace`).
4. **Lightweight shape version + monomorphic Inline Cache (IC) for `get_prop` / `set_prop`:**
   - Add a `u32` shape/layout version on `Object` (incremented on property add/delete/prototype change) and a 1-slot cache per property-access bytecode site mapping `(shape_id) -> prop_index`.
   - Turns repeated `o.x` reads into a direct slice index instead of a hash-table probe, without requiring full hidden-class transition trees yet.
5. **Hot superinstructions:**
   - Specialize the highest-frequency patterns (`get_local_0..3`, `inc_local`, `add_local_const`, `lt_jump_if_false`) guided by `sample` profiles.

---

## 3. Tier 2 — Interpreter Architecture (Target: 1.5×–2.5× Faster than QuickJS)

Medium-sized refactors, only pursued if profiling after Tier 1 justifies them:

1. **Shapes (hidden-class transition trees) + dense `[]Value` property arrays (D88) — DONE (M58):**
   - Moved property names/descriptors out of per-object `AutoArrayHashMapUnmanaged` into slab-pooled immutable `Shape` transition trees with 4 inline `Value` slots + overflow `[]Value` up to 64 properties (dictionary fallback for accessors, attribute mutations, non-tail deletes, and >64 props).
   - Cut `objects.js` by 25.5% (`1.54× → 1.18×` QuickJS, -52% allocs) and slashed `game_1m` / `game_big_container` / `frame_loop_3600` peak heap RAM by 40–65%.
2. **Register-based bytecode (or stack-top caching):**
   - Reduces instruction count and stack-shuffling overhead in numeric and loop-heavy workloads (the same architectural advantage JSC LLInt, V8 Ignition, and Lua 5.4 use to beat stack interpreters by 2×–3×).

---

## 4. Tier 3 — JIT: Tradeoffs & Why It Is Not Planned

"JIT" spans two very different tiers:

| Tier | Approach | Complexity | Typical Speedup vs Interpreter |
|---|---|---|---|
| **Baseline / Template JIT** | 1-to-1 bytecode → machine code templates (e.g. V8 Sparkplug, copy-and-patch). Eliminates dispatch overhead; calls runtime helpers for complex ops. | Medium–Hard (~3k–6k LOC per arch) | 2×–5× |
| **Optimizing / Speculative JIT** | Type-profiling + SSA IR + unboxed `i32`/`f64` codegen + guards + OSR/deoptimization back to interpreter frames (e.g. V8 TurboFan, LuaJIT, JSC FTL). | Very Hard (~25k–100k+ LOC) | 10×–50× |

### Why ZQJS prioritizes the interpreter over a JIT
- **Platform portability:** Dynamic executable memory (RWX / JIT) is forbidden on **iOS, consoles (Switch/PS5/Xbox), and WebAssembly** — primary targets for embeddable game scripting (`ROADMAP.md`).
- **Per-architecture maintenance:** Separate codegen, register allocation, calling conventions, and unwinding for `aarch64` and `x86_64` across macOS, Linux, and Windows.
- **Engine invariants:** Preserving exact GC rooting (native stack maps), cooperative step-budget slicing (`Execution.resume(budget)`), `yield`/`await` suspension, and precise exceptions across native machine frames adds substantial complexity.
- **Security & footprint:** JIT bugs are the dominant source of JS engine RCEs, and executable code caches increase memory usage and startup warmup.

*Future option:* If ever explored purely as an opt-in experiment, a small **arm64 Baseline JIT** behind a build flag (falling back to the interpreter everywhere else) is the only practical scope — an optimizing SSA JIT is out of scope for ZQJS.

---

## 5. Measurement & Correctness Rules

Every optimization step must follow the M10 discipline:
1. **Profile first, measure before & after** using `zig build bench-js` and `python3 tools/bench_compare.py` (comparing against both the previous commit and QuickJS).
2. **Revert any change that does not show a real speedup** (as in M10.4a).
3. **Never weaken invariants:** `zig fmt --check .`, `zig build check-goldens`, `ReleaseSafe`, `-Dgc-stress -Dstack-stress`, `gc-mutants`, and Test262 (`0` internal errors) must stay green after every optimization commit.
