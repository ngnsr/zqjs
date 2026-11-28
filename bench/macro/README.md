# Macro Benchmarks (`bench/macro/`)

Realistic, multi-subsystem JavaScript workloads that exercise parsing, closures, object shapes, GC, `Map`/`Set`, `JSON`, `RegExp`, and string building together.

Each workload:
- Uses a deterministic seeded PRNG in JS (no `Date.now` or `Math.random`).
- Prints a single `RESULT <checksum>` line that must match identically across `zqjs`, `qjs`, and `node`.
- Targets ~100–600 ms on a `ReleaseFast` `zqjs` build.

## Workloads

| File | Models |
|---|---|
| `schema_validate.js` | Zod-style schema validation (builder objects, closures, method chaining, error objects with path arrays) over 25,000 generated records |
| `json_roundtrip.js` | `JSON.stringify` / `JSON.parse` round-trips of 900 nested generated batches with a reviver function |
| `expr_eval.js` | Hand-written tokenizer, recursive-descent parser, and AST evaluator over 3,000 generated expression programs |
| `physics_tick.js` | Class-based 2D physics simulation (1,200 ticks) with `Vec2`/`Body`/`World`, `Map` spatial grid, `Set` collision deduplication, and array churn |
| `template_render.js` | Mustache-style interpolation + markdown-lite HTML rendering (2,500 documents) using `RegExp` and string building |

## Running

Run a single workload directly:
```sh
zig build cli -Doptimize=ReleaseFast
./zig-out/bin/zqjs bench/macro/schema_validate.js
qjs bench/macro/schema_validate.js
node bench/macro/schema_validate.js
```

Run the full macro comparison against QuickJS and Node:
```sh
python3.12 tools/bench_compare.py --suite macro
```
