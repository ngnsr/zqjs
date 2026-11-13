# zqjs

A small, embeddable JavaScript-like runtime written from scratch in Zig, built as a learning
project: lexer, parser, AST, bytecode compiler, stack VM, object model and garbage collector.
Inspired by QuickJS and Crafting Interpreters; it does not reuse their code.

Priorities: correctness, simplicity, inspectability. Speed comes last.

## Status
Milestone 3 of 11: ZQJS runs programs. A tree-walking interpreter executes expressions,
`let`/`const`, assignment, blocks, `if`/`while`/`for`, `break`/`continue` and `print(…)`, with
JavaScript's semantics for numbers, strings, `-0`, the temporal dead zone and `const`. Output is
checked byte for byte against node. See [ROADMAP.md](ROADMAP.md).

## Requirements
**Zig 0.17.1 exactly** (the build refuses other versions; see DESIGN_DECISIONS D17).

```sh
brew install zig && brew pin zig
```

node and Python 3 (standard library only) are needed only to regenerate or check test data
(`zig build update-golden`, `zig build check-goldens`), not to build or test.

## Usage
```sh
zig build                                   # builds zig-out/bin/zqjs
zig-out/bin/zqjs program.js                 # run a script (stops after 200M steps; --max-steps N, 0 = no limit)
zig-out/bin/zqjs -e "let s = ''; for (let i = 0; i < 3; i++) { s += i; } print(s, 0.1 + 0.2);"
# 012 0.30000000000000004
zig-out/bin/zqjs --dump-ast -e "let x = 1; { let x = x + 2; }"
# (let (x#0@0 1))
# (block (let (x#1@1 (+ x#1 2))))           ← inner x refers to itself: a TDZ error if run
zig build test                              # unit + integration tests (tests/all.zig)
zig build test --fuzz=100K                  # also fuzz parsing and execution
zig build check-goldens                     # verify syntax cases against node; generated files up to date
zig build update-golden                     # regenerate goldens (node) and pow references (Python)
```

## Documents
- [LANGUAGE.md](LANGUAGE.md): what ZQJS accepts and the compatibility contract with node
- [ARCHITECTURE.md](ARCHITECTURE.md): components and ownership
- [DESIGN_DECISIONS.md](DESIGN_DECISIONS.md): why things are the way they are
- [ROADMAP.md](ROADMAP.md): milestones and required regression tests
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md): licenses of ported code (musl/Arm `pow`)
