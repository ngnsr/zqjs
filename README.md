# zqjs

A small, embeddable JavaScript-like runtime written from scratch in Zig, built as a learning
project: lexer, parser, AST, bytecode compiler, stack VM, object model and garbage collector.
Inspired by QuickJS and Crafting Interpreters; it does not reuse their code.

Priorities: correctness, simplicity, inspectability. Speed comes last.

## Status
Milestone 2 of 11: the frontend parses expressions, `let`/`const`, assignment, blocks,
`if`/`while`/`for` and `break`/`continue`, and resolves every name to a scope slot or a global,
with precise diagnostics. Nothing executes yet. See [ROADMAP.md](ROADMAP.md).

## Requirements
**Zig 0.17.1 exactly** (the build refuses other versions; see DESIGN_DECISIONS D17).

```sh
brew install zig && brew pin zig
```

node (any recent version) is only needed for `zig build check-node`.

## Usage
```sh
zig build                                   # builds zig-out/bin/zqjs
zig build run -- --dump-ast -e "let x = 1; { let x = x + 2; }"
# (let (x#0@0 1))
# (block (let (x#1@1 (+ x#1 2))))   ← inner x refers to itself (TDZ in M3)
zig build test                              # unit + syntax-case tests
zig build test --fuzz=100K                  # also fuzz the parser
zig build check-node                        # verify syntax cases against node
```

## Documents
- [LANGUAGE.md](LANGUAGE.md): what ZQJS accepts and the compatibility contract with node
- [ARCHITECTURE.md](ARCHITECTURE.md): components and ownership
- [DESIGN_DECISIONS.md](DESIGN_DECISIONS.md): why things are the way they are
- [ROADMAP.md](ROADMAP.md): milestones and required regression tests
