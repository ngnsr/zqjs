# Architecture

```
source ─▶ Lexer ─▶ Parser ─▶ AST ─▶ Resolver ─▶ Compiler ─▶ FunctionProto (bytecode)
          └───── frontend: arena, freed after compile ────┘           │
                                                                       ▼
                        Runtime { Heap (GC), atoms, globals, Limits } ◀─▶ VM
                                              ▲
                                  Embedding API (Zig, later C ABI)
```

Dependencies point one way: frontend → compiler → runtime/VM. The frontend knows nothing about
the runtime.

## Built so far (M3)

| file | role |
|---|---|
| `src/frontend/token.zig` | `Token` (tag + byte span + `newline_before`) and the full JS punctuator set |
| `src/frontend/lexer.zig` | pull-based, allocation-free tokenizer. Validates numbers; finds string ends |
| `src/frontend/ast.zig` | `Expr` and `Stmt` nodes, `Ref` (variable use), `Declarator`, `Script` |
| `src/frontend/parser.zig` | statements + Pratt expression parser; decodes string literals to UTF-16; classifies errors |
| `src/frontend/resolver.zig` | scopes and names → binding ids, slots, globals; redeclaration and global-write checks |
| `src/frontend/dump.zig` | S-expression dump with resolved names (`x#binding@slot`, `x@global`) |
| `src/frontend/diag.zig` | `Diagnostic` (kind, feature, span), line/column, rendering with caret |
| `src/runtime/value.zig` | `Value` (tagged union) and `Native` |
| `src/runtime/heap.zig` | `Heap`: list of all objects, `String`, byte accounting and limits |
| `src/runtime/runtime.zig` | `Runtime`: heap, output, step budget, exception / stop reason |
| `src/runtime/ops.zig` | all JS value semantics: ToNumber, ToString (number formatting), ToBoolean, operators |
| `src/runtime/globals.zig` | `undefined`, `NaN`, `Infinity`, `print` |
| `src/interp/treewalk.zig` | tree-walking interpreter over AST + Resolution, `?Value` slots |
| `src/run.zig` | source → parse → resolve → run, with outcome reporting (CLI and tests share it) |
| `src/limits.zig` | `Limits` (only the limits enforced so far, see DESIGN_DECISIONS D15) |
| `src/root.zig` | library entry: `parse`, `resolve`, `dump`, `Runtime`, `interpret`, `runSource` |
| `src/main.zig` | CLI: `zqjs FILE`, `zqjs -e SRC`, `--test` (harness output), `--dump-ast` |

### Ownership in the frontend
- The lexer borrows the source and returns tokens by value; it allocates nothing.
- The parser allocates AST nodes and decoded strings from the **arena the caller passes**. The
  caller frees everything with one `arena.deinit()`, including after errors.
- Names in the AST are **slices of the source**: the source must outlive the AST.
- The resolver allocates its tables (and its scratch `live` stack) from the same arena, so a
  `Resolution` lives exactly as long as the AST it describes. It never modifies the AST.
- `Diagnostic` holds only offsets and enums. Rendering reads the source, so diagnostics
  never allocate and can't dangle while the source is alive.

### Error classification
The parser reports the *first* problem as one of `error.SyntaxError`, `error.Unsupported`,
`error.LimitExceeded` (or `error.OutOfMemory`). The rules for choosing SyntaxError versus
Unsupported follow the asymmetric default in LANGUAGE.md §1. For example, a token that cannot
continue an expression in *any* JavaScript (`;` `)` `]` `}` `,` EOF, a literal without a
line break) is a SyntaxError, while a valid-but-unimplemented token (`?`, `=`, `,` inside
parentheses, an identifier) is `Unsupported(syntax)`.

## Planned components
See DESIGN_DECISIONS.md: heap and GC (D7–D11), stack (D12), objects (D13), limits (D15),
oracle (D16).

### Runtime ownership (M3)
- Runtime values point into the `Heap`, never into the frontend arena; nothing created at
  runtime depends on the AST.
- Every heap object is on one linked list and is freed by `Runtime.deinit` (no GC until M8).
- The interpreter's slot array is allocated per run and freed when the run ends.
- A thrown exception's message is a heap string: it outlives unwinding, and the host reads
  it before `Runtime.deinit` (DESIGN_DECISIONS D27).

## Tests
```
src/**                    unit tests next to the code (`test` blocks)
tests/all.zig             root of all integration tests (through the public zqjs module)
tests/frontend_test.zig   allocation-failure paths + fuzzing of parse → resolve → dump
tests/interpreter_test.zig limits, allocation failures, exception ownership, fuzzing of runs
tests/syntax_test.zig     tests/syntax/cases.jsonl: outcome + resolved dump per source
tests/ops_test.zig        tests/ops/*.jsonl: conversions/operators vs node, bit for bit
tests/diff_test.zig       tests/diff/*.js: program output must equal node's tests/diff/*.out
tests/harness/            node scripts: golden.js (regenerate/check goldens), check_syntax_cases.js
```
- `zig build test` runs the unit and integration test binaries; `zig build test --fuzz` fuzzes.
- `zig build update-golden` regenerates `tests/ops` and `tests/diff/*.out` with node;
  `zig build check-node` verifies the syntax contract and that every golden is up to date.
