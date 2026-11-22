# zqjs

A fast, embeddable, zero-dependency JavaScript engine written from scratch in Zig — lexer, parser, resolver, bytecode compiler & verifier, NaN-boxed stack VM with Shapes and inline caches, generational garbage collector, interactive REPL, Zig embedding API, and C11 ABI.

Designed for host-controlled scripting (games, plugins, tools, sandboxed automation) where deterministic limits, small footprint, and portable interpreter performance (no JIT / no RWX memory) matter.

## Highlights

- **Faster than QuickJS on average (`0.96×` geomean):** Pure bytecode interpreter (no JIT / no RWX) with 8-byte NaN-boxed values, Shapes (hidden classes), inline caches, and fused superinstructions.
- **Zero dependencies & compact footprint:** Pure Zig (`0.17.1`), `2.2 MB` stripped `ReleaseFast` CLI (`1.5 MB` `ReleaseSmall`). Embedders (`@import("zqjs")` / `libzqjs.a`) link only the engine.
- **Modern JavaScript (ES2025 core):** Classes & private fields, closures, generators, `async`/`await`, ES Modules, `BigInt`, `Symbol`, `Proxy`/`Reflect`, `Map`/`Set`/`WeakMap`/`WeakSet`, `ArrayBuffer`/`TypedArray`/`DataView`, `RegExp`, `Date`, `Promise`, `JSON`, and `structuredClone` ([LANGUAGE.md](LANGUAGE.md)).
- **Explicit Compatibility Contract & Test262 Verified:** Unsupported features report `Unsupported(<feature>)` cleanly instead of silently misbehaving. Verified against **39,332 Test262 tests** (**`20,177` PASS** — `91.42%` applicable `built-ins`, `91.11%` applicable `language`, **0 crashes / 0 internal errors / 0 timeouts** — [TEST262.md](TEST262.md)).
- **Generational GC & Hard Sandboxing:** Non-moving generational GC (~0.06 ms p95 minor pauses at 100k–1M live objects), cooperative step slicing, and hard caps on heap, call depth, stack, strings, and `BigInt` ([GC_DESIGN.md](GC_DESIGN.md)).
- **Embeddable & Interactive:** Opaque Zig API, C11 ABI (`include/zqjs.h`), differential tree-walker oracle (`--engine=treewalk`), and an interactive REPL with syntax highlighting, `Tab` completion, and `Ctrl-R` history.

```js
// ZQJS prints: 6765 hi box:3 0,1,b,a
function fib(n) { if (n < 2) return n; return fib(n - 1) + fib(n - 2); }
const base = { describe() { return this.kind + ':' + this.size; } };
const box = Object.create(base); box.kind = 'box'; box.size = 3;
const greet = (function () { const word = 'hi'; return function () { return word; }; })();
print(fib(20), greet(), box.describe(), Object.keys({ b: 1, a: 2, 1: 3, 0: 4 }));
```

---

## Performance vs QuickJS

CLI-to-CLI end-to-end medians (startup + parse + compile + execute, 11 alternating runs, MacBook Air Apple M4, macOS arm64, Zig `0.17.1` `ReleaseFast`, QuickJS `2026-06-04`; faster engine **bolded** per row; full methodology and raw samples in [bench/suite/baseline-qjs.md](bench/suite/baseline-qjs.md) and [PERF_PLAN.md](PERF_PLAN.md)):

| Benchmark | ZQJS med | QuickJS med | Ratio (`zqjs/qjs`) |
|---|---:|---:|---:|
| `closures.js` | **62.0 ms** | 123.7 ms | **`0.50×`** (2× faster) |
| `branch_dense.js` | **71.8 ms** | 103.0 ms | **`0.70×`** (30% faster) |
| `int_loop.js` | **60.3 ms** | 68.4 ms | **`0.88×`** (12% faster) |
| `arrays.js` | **155.8 ms** | 165.5 ms | **`0.94×`** (6% faster) |
| `strings.js` | **11.8 ms** | 12.1 ms | **`0.98×`** (2% faster) |
| `scopes.js` | 36.3 ms | **35.4 ms** | `1.03×` |
| `float_math.js` | 140.5 ms | **134.2 ms** | `1.05×` |
| `fib.js` | 37.4 ms | **33.1 ms** | `1.13×` |
| `objects.js` | 39.3 ms | **33.0 ms** | `1.19×` |
| `global_reads.js` | 29.2 ms | **24.4 ms** | `1.20×` |
| `call_chain.js` | 65.6 ms | **50.6 ms** | `1.30×` |
| **Geometric mean** | — | — | **`0.96×`** |

**C-ABI embedding throughput (`zig build bench-c`):**
- `js_to_c_native`: **7.3M–8.3M calls/s** (~120–137 ns/call)
- `host_js_c_js_roundtrip`: **~4.0M round-trips/s** (~252 ns/trip)
- `frame_loop_3600` (3,600 game frames): **`11.0 µs` p50** / `12.0 µs` p95 per frame, `141 KiB` live heap

---

## Compatibility & Intentional Restrictions

ZQJS implements a clean, modern subset of ECMAScript with an explicit, testable contract ([LANGUAGE.md](LANGUAGE.md)):

| Outcome | Guarantee |
|---|---|
| **`ok`** | Matches Node 22 stdout and uncaught exception *name* |
| **`SyntaxError`** | Node 22 also rejects the program with a `SyntaxError` |
| **`Unsupported(id)`** | Explicitly outside ZQJS (terminates immediately; uncatchable, never silently wrong) |
| **`LimitExceeded(limit)`** | Configured resource limit hit (terminates immediately; uncatchable) |

Legacy sloppy-mode hazards are **intentionally excluded** by design rather than partially emulated:
- Automatic Semicolon Insertion (`asi` — semicolons required outside REPL), loose equality (`==`/`!=` — use `===`/`!==`), `with`, `eval` / `Function(...)`, `arguments` (use rest parameters `...args`), implicit global writes, sparse array holes, legacy octals, and sloppy `this` boxing.
- Standard built-ins outside ZQJS's scope (e.g. `Intl`, `Temporal`, `Atomics`, `SharedArrayBuffer`, `WeakRef`, `FinalizationRegistry`) report `Unsupported(builtin)` naming the exact identifier.

See [LANGUAGE.md](LANGUAGE.md) for the complete specification and [TEST262.md](TEST262.md) for the full 39,332-test conformance breakdown.

---

## Requirements

- **Zig `0.17.1` exactly** (enforced by `build.zig`; see `DESIGN_DECISIONS.md` D17).
- **Optional (dev/golden checks only):** Node `22.x` and Python 3 (stdlib only) for `zig build check-goldens`, `tools/bench_compare.py`, and `tools/test262.py`. Not required to build, embed, or run `zig build test`.

## Usage

```sh
# Build
zig build                                        # Debug CLI + libzqjs.a + include/zqjs.h
zig build cli -Doptimize=ReleaseFast -Dstrip=true # 2.2 MB stripped fast CLI
zig build cli -Doptimize=ReleaseSmall            # 1.5 MB auto-stripped compact CLI

# Run scripts & REPL
zig-out/bin/zqjs                                 # start interactive REPL (--repl, --no-color)
zig-out/bin/zqjs program.js                      # run script (--max-steps N, 0 = unlimited)
zig-out/bin/zqjs --module app.mjs                # run ES module (.mjs auto-enables --module)
zig-out/bin/zqjs -e "print(0.1 + 0.2);"
zig-out/bin/zqjs --dump-ast -e "let x = 1;"
zig-out/bin/zqjs --dump-bytecode -e "let x = 1; x += 2;"
zig-out/bin/zqjs --trace -e "print(1 + 2);"      # instruction + operand stack trace
zig-out/bin/zqjs --engine=treewalk program.js    # run on the reference interpreter

# Test & verify
zig build test -Doptimize=ReleaseSafe --summary all
zig build test -Dgc-stress -Dstack-stress -Doptimize=ReleaseSafe --summary all
zig build gc-mutants                             # deliberately broken GC builds must be caught
zig build check-goldens                          # verify syntax/diff goldens against Node 22
zig build test --fuzz=100K -Dtest-filter="fuzz: frontend"

# Benchmarks
zig build bench-js                               # split-phase VM benchmarks (bench/suite/js/)
zig build bench-js -- --gc                       # include 100k/1M-object game GC workloads
zig build bench-c                                # C-ABI embedding benchmarks
python3 tools/bench_compare.py                   # full CLI-to-CLI comparison vs QuickJS
zig build gc-report                              # detailed GC pause & allocation-rate report

# Examples
zig build example                                # Zig embedding API example (examples/embed.zig)
zig build plugin-host                            # C11 multi-plugin host (examples/plugin_host.c)
```

---

## Embedding

### Zig API (`@import("zqjs")`)
ZQJS exposes an opaque, GC-safe embedding API ([EMBEDDING.md](EMBEDDING.md)) designed for host-controlled loops:
- **Private internals:** `Runtime`, `Program`, `Execution`, and generational `Handle`s keep the VM, stack, and GC private.
- **Cooperative slicing & hard caps:** run scripts in bounded step slices per frame under cumulative step/heap/stack limits.
- **Errors over panics:** all syntax, runtime, and limit failures return Zig errors and non-allocating UTF-8 `Failure` records.

### C11 ABI (`include/zqjs.h`, `libzqjs.a`)
```sh
zig build -Doptimize=ReleaseFast -Dstrip=true
cc -std=c11 -Izig-out/include examples/c_embed.c zig-out/lib/libzqjs.a -lpthread -o c_embed
./c_embed
```

```c
#include "zqjs.h"
#include <stdio.h>
#include <string.h>

static bool on_print(void *ctx, const char *bytes, size_t len) {
    (void)ctx;
    return fwrite(bytes, 1, len, stdout) == len;
}

int main(void) {
    if ((zqjs_abi_version() >> 16) != ZQJS_ABI_MAJOR) return 1;
    zqjs_options opts = zqjs_options_default();
    opts.output_fn = on_print;

    zqjs_runtime *rt = NULL;
    if (zqjs_runtime_create(&opts, &rt) != ZQJS_OK) return 1;

    const char *src = "print('hello from C');";
    zqjs_program *prog = NULL;
    zqjs_diagnostic diag;
    if (zqjs_runtime_compile(rt, "app.js", 6, src, strlen(src), &diag, &prog) == ZQJS_OK) {
        zqjs_failure fail;
        zqjs_runtime_run(rt, prog, &fail);
        zqjs_program_destroy(prog);
    }
    zqjs_runtime_destroy(rt);
    return 0;
}
```

For a C11 multi-plugin cooperative host, see [examples/plugin_host.c](examples/plugin_host.c) (`zig build plugin-host`). For a Raylib game demo scripted in ZQJS (optional Raylib dependency; `zig build test` stays Raylib-free), see [examples/raylib_c_demo.c](examples/raylib_c_demo.c) or [zqjs-raylib](https://github.com/ngnsr/zqjs-raylib):
```sh
zig build raylib-smoke   # headless 60-frame + error-handling smoke test
zig build raylib-demo    # interactive GUI window (requires Raylib)
```

---

## Documents

- [EMBEDDING.md](EMBEDDING.md) — Zig & C11 embedding API (lifecycle, handles, step slices, modules, errors)
- [LANGUAGE.md](LANGUAGE.md) — supported JavaScript subset and Node compatibility contract
- [TEST262.md](TEST262.md) — ECMAScript Test262 conformance runner and M59 results (39,332 tests)
- [PERF_PLAN.md](PERF_PLAN.md) — performance architecture, M52–M59 progression, and why JIT is deferred
- [ARCHITECTURE.md](ARCHITECTURE.md) — module layout and ownership
- [GC_DESIGN.md](GC_DESIGN.md) — generational collector, card tables, ephemerons, and verification
- [DESIGN_DECISIONS.md](DESIGN_DECISIONS.md) — architectural decision log (D1–D89)
- [ROADMAP.md](ROADMAP.md) — milestone history (M1–M59) and remaining work
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) — licenses of ported code (musl/Arm `pow`)
