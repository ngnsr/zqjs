# zqjs

A small, embeddable JavaScript-like runtime written from scratch in Zig, built as a learning
project: lexer, parser, AST, bytecode compiler, stack VM, object model and garbage collector.
Inspired by QuickJS and Crafting Interpreters; it does not reuse their code.

Priorities: correctness, simplicity, inspectability. Speed comes last.

## Status
Milestone 8 of 11 done (tags `m1` … `m8`, and `p1` for accurate `**`). ZQJS has:

- **the language so far:** `let`/`const`, blocks, `if`/`while`/`for`, `break`/`continue`;
  functions, closures and recursion; objects, arrays, prototypes, methods with `this`; numbers,
  UTF-16 strings, `-0`, the temporal dead zone, `const`; a few built-ins (`print`,
  `Object.keys/create/getPrototypeOf`, `Array.isArray`, `push`/`pop`/`join`, `charCodeAt`).
  Everything else node has is reported as `Unsupported(…)`, never silently wrong
  ([LANGUAGE.md](LANGUAGE.md)).
- **two engines that must agree:** a bytecode compiler, verifier and stack VM (the default),
  and a tree-walking reference interpreter (`--engine=treewalk`). Their output is checked byte
  for byte against node, and against each other under fuzzing.
- **a garbage collector:** stop-the-world, non-moving, precise mark-and-sweep, running at
  safepoints in both engines, with weak atoms, a stress mode (`-Dgc-stress`) and a heap verifier
  ([GC_DESIGN.md](GC_DESIGN.md)). A program whose live data fits the heap limit runs as long as
  its step budget allows, however much garbage it makes.

```js
// ZQJS prints 6765 hi box:3 0,1,b,a. `print` is ZQJS's own built-in, so node needs one defined
// first to print the same (tests/harness/golden.js uses `console.log(a.map(String).join(' '))`).
function fib(n) { if (n < 2) return n; return fib(n - 1) + fib(n - 2); }
const base = { describe() { return this.kind + ':' + this.size; } };
const box = Object.create(base); box.kind = 'box'; box.size = 3;
const greet = (function () { const word = 'hi'; return function () { return word; }; })();
print(fib(20), greet(), box.describe(), Object.keys({ b: 1, a: 2, 1: 3, 0: 4 }));
```

Next: M9 (embedding API, with a small Raylib demo), M10 (fuzzing and benchmarks), M11
(bytecode debugger). The collector's next step is decided by measuring it first (ROADMAP). See [ROADMAP.md](ROADMAP.md).

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
zig build                                   # builds zig-out/bin/zqjs
zig-out/bin/zqjs program.js                 # run a script (stops after 200M steps; --max-steps N, 0 = no limit)
zig-out/bin/zqjs -e "let s = ''; for (let i = 0; i < 3; i++) { s += i; } print(s, 0.1 + 0.2);"
# 012 0.30000000000000004
zig-out/bin/zqjs --dump-ast -e "let x = 1; { let x = x + 2; }"
# (let (x#0@0 1))
# (block (let (x#1@1 (+ x#1 2))))           ← inner x refers to itself: a TDZ error if run
zig-out/bin/zqjs --dump-bytecode -e "let x = 1; x += 2;"   # compiled, verified, listed (M4)
zig-out/bin/zqjs --trace -e "print(1 + 2);"                # each VM instruction and the stack, on stderr
zig-out/bin/zqjs --engine=treewalk program.js               # the reference interpreter instead of the VM
zig build test                              # unit + integration tests (tests/all.zig)
zig build test -Dstack-stress               # same, with the VM moving its stacks on every call
zig build test -Dgc-stress                  # same, collecting at every safepoint, with tombstones and a heap verifier
zig build test --fuzz=100K -Dtest-filter="fuzz: frontend"   # fuzz one target (only one runs per call):
                                            #   "fuzz: frontend", "fuzz: both engines agree",
                                            #   "fuzz: anything the front end", "fuzz: the verifier"
zig build bench                             # bench/*.js on both engines: steps, heap bytes, median ms
zig build check-goldens                     # verify syntax cases against node; generated files up to date
zig build update-golden                     # regenerate goldens (node) and pow references (Python)
```

## Benchmarks
`zig build bench` (always ReleaseFast) runs every `bench/*.js` five times in-process on both
engines, each run with a fresh runtime and heap. `steps` and the heap columns are
deterministic (identical on every machine, and checked identical across runs): `allocated` is
the cumulative volume charged, `peak` the highest live total, `end` what is live at the end
(they differ as soon as garbage is collected during a run). `median ms` only compares on the same
machine. `collections` counts garbage collections during the run. `bench/baseline.txt` is the
current baseline (end of M8, Apple M4); `bench/baseline-m7.txt` is the end of M7, kept to compare
against (the M6 reference point is commit abbf773). Rerun and diff before and after a change: a
change in steps or heap means different work, a change in time alone means the same work got
faster or slower.

## Continuous integration
`.github/workflows/ci.yml` runs on every push that touches code, tests, tools or the build
(documentation-only changes skip it), on macOS arm64, Linux x86_64 and Linux arm64:
`zig fmt --check .`, `zig build test` (also with `-Dgc-stress -Dstack-stress`, in ReleaseSafe,
and with `-Dgc-stress` in ReleaseSafe),
`zig build check-goldens`, `zig build --release=fast`, and a check that `pow` produces the same
bits as the reference hash (DESIGN_DECISIONS D25).

## Documents
- [LANGUAGE.md](LANGUAGE.md): what ZQJS accepts and the compatibility contract with node
- [ARCHITECTURE.md](ARCHITECTURE.md): components and ownership
- [DESIGN_DECISIONS.md](DESIGN_DECISIONS.md): why things are the way they are
- [ROADMAP.md](ROADMAP.md): milestones, required regression tests, technical debt
- [GC_DESIGN.md](GC_DESIGN.md): the garbage collector's design (M8, proposal under review)
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md): licenses of ported code (musl/Arm `pow`)
