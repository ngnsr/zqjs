# zqjs

A small, embeddable JavaScript-like runtime written from scratch in Zig, built as a learning
project: lexer, parser, AST, bytecode compiler, stack VM, object model and garbage collector.
Inspired by QuickJS and Crafting Interpreters; it does not reuse their code.

Priorities: correctness, simplicity, inspectability. Speed comes last.

## Status
Milestones 1–41 done ([ROADMAP.md](ROADMAP.md), [DESIGN_DECISIONS.md](DESIGN_DECISIONS.md)). ZQJS has:

- **the language so far:** `let`/`const`, destructuring, blocks, `if`/`while`/`for`, `for...of`, `for...in`, `switch`,
  `break`/`continue`, `try`/`catch`/`finally`/`throw`; functions, arrows, classes (inheritance, `super`, private
  fields/methods), closures, recursion, generators (`function*`/`yield`/`yield*`), `async`/`await`, and async
  generators (`async function*`/`for await`); numbers, UTF-16 strings, template literals, `RegExp`, `Symbol`
  (`Symbol.for`/`keyFor`, well-known symbols), `-0`, the temporal dead zone, `const`; `Map`, `Set`, built-in
  iterators, `JSON.parse`/`JSON.stringify`, `Promise` (`.then`/`.catch` and microtask checkpoints), and `Object` /
  `Array` / `String` / `Number` / `Math` / `Error` built-ins. Everything else node has is reported as
  `Unsupported(…)`, never silently wrong ([LANGUAGE.md](LANGUAGE.md)).
- **interactive REPL (`zqjs`):** persistent `let`/`const`/`function`/`class` bindings across lines, top-level
  `await`/`for await`, cycle-safe Node-style value inspector, raw-mode UTF-8 line editor with `Ctrl-R` history
  search, live syntax highlighting, read-only `Tab` completion, and dot-commands (`.help`, `.ast`, `.bc`, `.gc`, …).
- **two engines that must agree:** a bytecode compiler, verifier and stack VM (the default),
  and a tree-walking reference interpreter (`--engine=treewalk`). Their output is checked byte
  for byte against node, and against each other under fuzzing.
- **a generational garbage collector:** non-moving and precise, running at safepoints in both
  engines.
  - A 256 KiB nursery is swept by minor collections that never trace the old generation.
  - A remembered set with array and property-table cards keeps track of old-to-young
    references.
  - Major collections are adaptively scheduled. Atoms are weak.
  - It comes with a stress mode (`-Dgc-stress`), a heap verifier, and deliberately broken
    builds the verifier must catch (`zig build gc-mutants`).
  - On the game workloads, minor pauses are about 0.06 ms (p95) at 100k or 1M live objects
    ([GC_DESIGN.md](GC_DESIGN.md) §15).
  - A program whose live data fits the heap limit runs as long as its step budget allows,
    however much garbage it makes.

```js
// ZQJS prints 6765 hi box:3 0,1,b,a. `print` is ZQJS's own built-in, so node needs one defined
// first to print the same (tests/harness/golden.js uses `console.log(a.map(String).join(' '))`).
function fib(n) { if (n < 2) return n; return fib(n - 1) + fib(n - 2); }
const base = { describe() { return this.kind + ':' + this.size; } };
const box = Object.create(base); box.kind = 'box'; box.size = 3;
const greet = (function () { const word = 'hi'; return function () { return word; }; })();
print(fib(20), greet(), box.describe(), Object.keys({ b: 1, a: 2, 1: 3, 0: 4 }));
```

See [ROADMAP.md](ROADMAP.md) for milestone details, required regression tests, and planned work.

## Requirements
**Zig 0.17.1 exactly** (the build refuses other versions; see DESIGN_DECISIONS D17).

```sh
brew install zig && brew pin zig
```

node **22.x exactly** and Python 3 (standard library only) are needed only to regenerate or check
test data and the node-generated built-in inventory (`zig build update-golden`,
`zig build check-goldens`), not to build or test. The goldens record node 22's answers and a newer
node gives different ones (26 prints `1e-29` where 22 prints `1.0000000000000001e-29`), so
`check-goldens` fails under it.

## Usage
```sh
zig build                                   # builds zig-out/bin/zqjs (or -Doptimize=ReleaseSafe)
zig-out/bin/zqjs                            # start interactive REPL (--repl, --no-color)
zig-out/bin/zqjs program.js                 # run a script (stops after 200M steps; --max-steps N, 0 = no limit)
zig-out/bin/zqjs -e "let s = ''; for (let i = 0; i < 3; i++) { s += i; } print(s, 0.1 + 0.2);"
# 012 0.30000000000000004
zig-out/bin/zqjs --dump-ast -e "let x = 1; { let x = x + 2; }"
# (let (x#0@0 1))
# (block (let (x#1@1 (+ x#1 2))))           ← inner x refers to itself: a TDZ error if run
zig-out/bin/zqjs --dump-bytecode -e "let x = 1; x += 2;"   # compiled, verified, listed (M4)
zig-out/bin/zqjs --trace -e "print(1 + 2);"                # each VM instruction and the stack, on stderr
zig-out/bin/zqjs --engine=treewalk program.js               # the reference interpreter instead of the VM
zig build test                              # unit + integration tests (tests/*_test.zig, in parallel)
zig build test -Dstack-stress               # same, with the VM moving its stacks on every call
zig build test -Dgc-stress                  # same, collecting at every safepoint, with tombstones and a heap verifier
zig build test --fuzz=100K -Dtest-filter="fuzz: frontend"   # fuzz one target (only one runs per call):
                                            #   "fuzz: frontend", "fuzz: both engines agree",
                                            #   "fuzz: anything the front end", "fuzz: the verifier"
zig build bench                             # bench/*.js on both engines: steps, heap bytes, median ms
zig build m10-bench                         # M10 split-phase ZQJS benchmarks (ReleaseFast)
zig build m10-c-bench                       # M10 C-ABI embedding benchmarks (ReleaseFast)
zig build gc-report                         # GC pauses (minor/major), rates, GC share; bench/ and bench/gc/
zig build gc-report -- --nursery=1M game_   # another nursery size, only the game workloads
zig build gc-mutants                        # each deliberately broken GC piece must be caught
zig build check-goldens                     # verify syntax cases against node; generated files up to date
zig build update-golden                     # regenerate goldens (node) and pow references (Python)
zig build example                           # run the embedding API example (examples/embed.zig)
zig build plugin-host                       # build and run the M13 multi-plugin C11 host (examples/plugin_host.c)
```

## Embedding
ZQJS provides a private-VM Zig embedding API (`@import("zqjs")`) designed for host-controlled execution (games, tools, event loops):
- **Opaque handles:** `Runtime`, `Program`, `Execution`. The VM, stack layout, and GC internals remain private.
- **Slices and step limits:** cooperative multitasking running executions in bounded step slices per frame, under cumulative lifetime caps.
- **Results over panics:** syntax and execution errors return Zig errors and non-allocating UTF-8 `Failure` records.

See [EMBEDDING.md](EMBEDDING.md) for full details, semantics, and examples.

### C ABI (`include/zqjs.h`, `libzqjs.a`)
Build and install the C header and static library with `zig build`:
```sh
zig build
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

For a C11 multi-plugin cooperative host example, see [examples/plugin_host.c](examples/plugin_host.c) (`zig build plugin-host`).

For a full C11 host loop with structured `initGame({ update, draw, state })` handles (optional Raylib dependency — `zig build test` stays Raylib-free; pass `-Draylib-prefix=<path>` if Raylib isn't in a default location), see [examples/raylib_c_demo.c](examples/raylib_c_demo.c) or the standalone [zqjs-raylib](https://github.com/ngnsr/zqjs-raylib) repository:
```sh
zig build raylib-smoke   # headless 60-frame + error-handling smoke test
zig build raylib-demo    # interactive GUI window (requires Raylib)
```

## Benchmarks
`zig build bench` (always ReleaseFast) runs every `bench/*.js` five times in-process on both
engines, each run with a fresh runtime and heap. `steps` and the heap columns are
deterministic (identical on every machine, and checked identical across runs): `allocated` is
the cumulative volume charged, `peak` the highest live total, `end` what is live at the end
(they differ as soon as garbage is collected during a run). `median ms` only compares on the same
machine. `collections` counts garbage collections during the run. `bench/baseline.txt` is the
current baseline (end of M8.1, Apple M4, smp_allocator). The older ones are kept to compare
against:
- `bench/baseline-m8-smp.txt`: M8's code on the same allocator;
- `bench/baseline-m8.txt` and `bench/baseline-m7.txt`: the end of M8 and M7, on libc malloc;
- the M6 reference point is commit abbf773.

Times compare only between rows on the same allocator. `zig build gc-report` measures the
collector itself: pauses (minor and major), allocation rate and GC share, 5 runs per row, on
bench/ and the game-like workloads in bench/gc/. Its baselines are in `bench/gc/`. Rerun and diff before and after a change: a
change in steps or heap means different work, a change in time alone means the same work got
faster or slower.

## Continuous integration
`.github/workflows/ci.yml` runs on every push that touches code, tests, tools or the build
(documentation-only changes skip it), on macOS arm64, Linux x86_64 and Linux arm64.
- **Test configurations,** one parallel job each: `zig build test`, with
  `-Dgc-stress -Dstack-stress`, in ReleaseSafe, and with `-Dgc-stress` in ReleaseSafe.
- **The plain-tests job also runs** `zig fmt --check .`, `zig build gc-mutants`,
  `zig build check-goldens`, `zig build --release=fast`, and a check that `pow` produces the
  same bits as the reference hash (DESIGN_DECISIONS D25).
- **Watchdog:** each test binary aborts, naming itself, if it ever runs far longer than it
  should.

## Documents
- [EMBEDDING.md](EMBEDDING.md): embedding ZQJS in Zig (lifecycle, slices, step caps, errors)
- [LANGUAGE.md](LANGUAGE.md): what ZQJS accepts and the compatibility contract with node
- [ARCHITECTURE.md](ARCHITECTURE.md): components and ownership
- [DESIGN_DECISIONS.md](DESIGN_DECISIONS.md): why things are the way they are
- [ROADMAP.md](ROADMAP.md): milestones, required regression tests, technical debt
- [GC_DESIGN.md](GC_DESIGN.md): the garbage collector's design (M8; generations in §15, M8.1)
- [TEST262.md](TEST262.md): ECMAScript Test262 conformance runner, baseline results (M47), and spec edge cases
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md): licenses of ported code (musl/Arm `pow`)
