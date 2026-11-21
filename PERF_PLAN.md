# Performance & Optimization Plan

This document records the post-M10 performance roadmap for ZQJS: what we already achieved, how to reach and surpass QuickJS as a **pure, portable interpreter**, and why a JIT is intentionally deferred.

---

## 1. Where We Stand

At the M10 checkpoint (`05c0c7a`, see `ROADMAP.md` and `bench/m10/baseline-qjs.md`), ZQJS's stack VM — **without** NaN-boxing, hidden classes, inline caches, or threaded dispatch — measured:

- **Closures (`closures.js`):** `0.75×` QuickJS (faster than QuickJS)
- **Objects, fib, loops, arrays, calls:** `1.66×–2.33×` QuickJS
- **C-ABI throughput:** `~6.59M calls/s` (`js_to_c_native`), `~4.87M trips/s` (`host_js_c_js_roundtrip`), `18.0 µs` p50 per frame on `frame_loop_3600`

QuickJS uses reference counting (inc/dec on every stack move), 16-byte `JSValue` on 64-bit platforms, and no inline caches. Because ZQJS already has a tracing generational GC (zero refcount traffic in hot loops) and isolated value/stack representations (D5, D12, D35, D36), matching and beating QuickJS as a pure interpreter is realistic without a rewrite.

---

## 2. Tier 1 — Localized Interpreter Speedups (Target: QuickJS Parity)

Low-risk, localized changes that preserve the current bytecode architecture, verifier, and dual-engine parity:

1. **8-byte NaN-boxed `Value` (D5):**
   - Shrink `Value` from 16 bytes to 8 bytes inside `src/runtime/value.zig` (all other modules already go through accessors).
   - Halves memory bandwidth for operand stacks, locals, cells, and dense arrays.
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
