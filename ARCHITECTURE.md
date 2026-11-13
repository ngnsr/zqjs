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

## Built so far (M2)

| file | role |
|---|---|
| `src/frontend/token.zig` | `Token` (tag + byte span + `newline_before`) and the full JS punctuator set |
| `src/frontend/lexer.zig` | pull-based, allocation-free tokenizer. Validates numbers; finds string ends |
| `src/frontend/ast.zig` | `Expr` and `Stmt` nodes, `Ref` (variable use), `Declarator`, `Script` |
| `src/frontend/parser.zig` | statements + Pratt expression parser; decodes string literals to UTF-16; classifies errors |
| `src/frontend/resolver.zig` | scopes and names → binding ids, slots, globals; redeclaration and global-write checks |
| `src/frontend/dump.zig` | S-expression dump with resolved names (`x#binding@slot`, `x@global`) |
| `src/frontend/diag.zig` | `Diagnostic` (kind, feature, span), line/column, rendering with caret |
| `src/limits.zig` | `Limits` (only the limits enforced so far, see DESIGN_DECISIONS D15) |
| `src/root.zig` | library entry: `parse`, `resolve`, `dump` |
| `src/main.zig` | CLI: `zqjs --dump-ast FILE` / `zqjs --dump-ast -e SOURCE` |

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

## Tests
- Unit tests live next to the code (`test "…"` blocks).
- `tests/syntax/cases.jsonl`: one `[outcome, source, expected_dump?]` per line, checked by
  `tests/syntax_test.zig` (ZQJS) and `tests/harness/check_syntax_cases.js` (node).
- `src/frontend/frontend_test.zig`: allocation-failure paths and the fuzz target over the whole
  frontend (parse → resolve → dump); `zig build test --fuzz` runs the fuzzer.
