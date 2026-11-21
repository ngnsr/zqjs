# Performance & Optimization Plan

This document records the post-M10 performance roadmap for ZQJS: what we already achieved, how to reach and surpass QuickJS as a **pure, portable interpreter**, and why a JIT is intentionally deferred.

---

## 1. Where We Stand

At the M10 checkpoint (`05c0c7a`, see `ROADMAP.md` and `bench/m10/baseline-qjs.md`), ZQJS's stack VM — **without** NaN-boxing, hidden classes, inline caches, or threaded dispatch — measured:

- **Closures (`closures.js`):** `0.75×` QuickJS (faster than QuickJS)
- **Objects, fib, loops, arrays, calls:** `1.66×–2.33×` QuickJS
- **C-ABI throughput:** `~6.59M calls/s` (`js_to_c_native`), `~4.87M trips/s` (`host_js_c_js_roundtrip`), `18.0 µs` p50 per frame on `frame_loop_3600`

### M52–M56 Checkpoints (D82–D86 — Property IC, Superinstructions, 8-Byte NaN-Boxed `Value`/`Slot`, Back-Edge Safepoints & Fast Calls)

After M52–M56 (measured via `python3 tools/m10_compare.py`, Apple M4, Zig `0.17.1` `ReleaseFast`, QuickJS `2026-06-04`), CLI-to-CLI ratios vs QuickJS reached near-parity across almost all workloads (and nearly 2× faster than QuickJS on closures):

| Benchmark | Pre-M52 (`zqjs/qjs`) | M55 (`zqjs/qjs`) | **M56 (`zqjs/qjs`)** | ZQJS CLI med |
|---|---:|---:|---:|---:|
| `closures.js` | `0.77×` (95.2 ms) | `0.63×` (77.5 ms) | **`0.53×`** | **66.4 ms** (47% faster than QJS) |
| `branch_dense.js` | `1.91×` (200.8 ms) | `1.16×` (120.5 ms) | **`1.07×`** | **112.6 ms** (-44%) |
| `float_math.js` | `2.14×` (286.7 ms) | `1.19×` (158.5 ms) | **`1.10×`** | **150.4 ms** (-48%) |
| `arrays.js` | `2.42×` (400.0 ms) | `1.16×` (191.2 ms) | **`1.13×`** | **188.7 ms** (-53%) |
| `scopes.js` | `2.38×` (84.1 ms) | `1.38×` (48.0 ms) | **`1.15×`** | **41.1 ms** (-51%) |
| `int_loop.js` | `2.07×` (141.9 ms) | `1.24×` (83.8 ms) | **`1.17×`** | **80.6 ms** (-43%) |
| `fib.js` | `1.90×` (64.3 ms) | `1.64×` (53.9 ms) | **`1.26×`** | **42.2 ms** (-34%) |
| `call_chain.js` | `2.37×` (122.0 ms) | `1.58×` (80.3 ms) | **`1.34×`** | **68.2 ms** (-44%) |
| `global_reads.js` | `2.61×` (64.4 ms) | `1.59×` (38.6 ms) | **`1.35×`** | **33.5 ms** (-48%) |
| `objects.js` | `2.37×` (75.4 ms) | `1.65×` (52.4 ms) | **`1.56×`** | **51.0 ms** (-32%) |
| `strings.js` | `2.31×` (26.3 ms) | `1.95×` (22.7 ms) | **`1.94×`** | **22.3 ms** (-15%) |

*Note:* Labeled-switch threaded dispatch with `noinline` cold handlers and expanding `FrameCache` with `stack`/`locals` pointers both regressed due to register spilling and I-cache bloat, and were reverted per §5.

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

1. **Shapes (hidden-class transition trees) + dense `[]Value` property arrays:**
   - Move property names/descriptors out of per-object `AutoArrayHashMapUnmanaged` into shared immutable `Shape` descriptors, leaving each ordinary `Object` with a compact `shape: *Shape` + `slots: []Value`.
   - Cuts per-object memory footprint and makes monomorphic/polymorphic ICs trivial and fast across all instances of a class or object literal.
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
1. **Profile first, measure before & after** using `zig build bench` and `tools/m10_compare.py` (comparing against both the previous commit and QuickJS).
2. **Revert any change that does not show a real speedup** (as in M10.4a).
3. **Never weaken invariants:** `zig fmt --check .`, `zig build check-goldens`, `ReleaseSafe`, `-Dgc-stress -Dstack-stress`, `gc-mutants`, and Test262 (`0` internal errors) must stay green after every optimization commit.
