# The ZQJS language

ZQJS is a **deliberately limited JavaScript-like language**. This document defines what we
promise. Anything not listed here is not part of the language, even if it happens to work.

Three layers are kept apart:

- **ZQJS language**: this document; grows milestone by milestone.
- **ZQJS runtime**: VM, heap, objects, host API (see ARCHITECTURE.md).
- **ECMAScript compatibility**: measured (number of differential tests passing), never claimed.

## 1. The compatibility contract

Every program ends in exactly one outcome (DESIGN_DECISIONS D14):

| outcome | promise |
|---|---|
| **ok** | node accepts the program and, once execution exists (M3+), prints the same stdout and the same uncaught error *name* |
| **SyntaxError** | node also rejects the program with a SyntaxError |
| **Unsupported(feature)** | no promise: the program is outside ZQJS. Terminates the script; **cannot be caught** by JS code |
| **LimitExceeded(limit)** | a configured resource limit was hit. Terminates the script; cannot be caught |

**Asymmetric default.** We report `SyntaxError` only when certain that node rejects the program.
When in doubt we report `Unsupported`, which makes no claim and therefore can't be wrong.

**Not compared with node, ever:** error *messages*, stack traces, `console.log` formatting
(ZQJS has `print`, which uses `String(x)`), resource-limit thresholds, timing.

How it is checked: `tests/syntax/cases.jsonl` lists inputs with their expected outcome.
`zig build test` checks ZQJS against it; `zig build check-node` checks node against it
(every `ok` must parse in node, every `syntax` must be a node SyntaxError).

## 2. Unsupported features

Each `Unsupported` diagnostic names one of these stable ids.
**Restrictions** are permanent by design. **Not yet** means planned or undecided.

| id | kind | examples | why |
|---|---|---|---|
| `asi` | restriction | `1 + 2` at end of file, `1\n2;` | statements must end with `;`. ASI rules are a classic source of surprises |
| `loose_equality` | restriction | `a == b`, `a != b` | use `===`/`!==`. Avoids the abstract-equality coercion table |
| `legacy_octal` | restriction | `017`, `09`, `'\1'`, `'\08'` | sloppy-mode legacy syntax |
| `non_ascii_source` | restriction | `é = 1`, NBSP outside strings | identifiers and whitespace are ASCII only. Non-ASCII is fine inside strings and comments |
| `invalid_utf8` | restriction | malformed bytes in the source file | source must be valid UTF-8 |
| `numeric_separator` | not yet | `1_000` | |
| `non_decimal_literal` | not yet | `0x10`, `0o7`, `0b1` | |
| `bigint` | not yet | `10n` | |
| `syntax` | not yet | identifiers, `?:`, `,`, `~`, `=`, arrow functions, regexes … | any JS token or construct not yet in the grammar below |

## 3. Lexical grammar (M1)

- **Source**: UTF-8 bytes, at most `Limits.max_source_bytes` (default 16 MiB).
- **Whitespace**: space, tab, `\v`, `\f`, `\n`, `\r`.
- **Comments**: `// …` to end of line; `/* … */` (unterminated → SyntaxError).
- **Numbers**: `DecimalDigits [. DecimalDigits?] [ (e|E) [+|-] DecimalDigits ]` or
  `. DecimalDigits [exponent]`. Leading `0` followed by a digit → `Unsupported(legacy_octal)`.
  `e` without digits → SyntaxError. A number immediately followed by an identifier character or
  digit → SyntaxError (`3in`, `1.5.3`), except `n` (`bigint`) and `_` (`numeric_separator`).
  Values are IEEE-754 doubles, correctly rounded; overflow gives `Infinity`.
- **Strings**: `'…'` or `"…"`, decoded to **UTF-16 code units**. A raw line feed or carriage
  return inside the literal → SyntaxError. Escapes:

  | escape | result |
  |---|---|
  | `\b \f \n \r \t \v` | the usual control characters |
  | `\0` (not followed by a digit) | U+0000 |
  | `\xHH` | one code unit (exactly 2 hex digits, else SyntaxError) |
  | `\uHHHH` | one code unit; **lone surrogates allowed** (`'\uD800'` has length 1) |
  | `\u{H…}` | code point ≤ 10FFFF (else SyntaxError); above FFFF → surrogate pair |
  | `\` + line terminator (LF, CR, CRLF, U+2028, U+2029) | nothing (line continuation) |
  | `\1`–`\9`, `\0` + digit | `Unsupported(legacy_octal)` |
  | `\` + any other character | that character (`'\q'` is `"q"`) |

  Non-ASCII characters in the literal are decoded from UTF-8; those above U+FFFF become a
  surrogate pair, so `'😀'`, `'\u{1F600}'` and `'😀'` are the same string.
- **Keywords** used so far: `true false null`. Other identifiers: `Unsupported(syntax)` (M2).

## 4. Syntactic grammar (M1)

```
Script     := Statement*
Statement  := ';'                              (empty statement)
            | Expression ';'
Expression := Logical
Logical    := Logical ('||' | '&&') Logical      (&& binds tighter than ||)
            | Equality
Equality   := Equality ('===' | '!==') Relational | Relational
Relational := Relational ('<' | '<=' | '>' | '>=') Additive | Additive
Additive   := Additive ('+' | '-') Mult | Mult
Mult       := Mult ('*' | '/' | '%') Exp | Exp
Exp        := Unary | Primary '**' Exp           (right-associative)
Unary      := ('-' | '+' | '!') Unary | Primary
Primary    := Number | String | 'true' | 'false' | 'null' | '(' Expression ')'
```

Notable rules, all matching JavaScript:
- `2 ** 3 ** 2` is `2 ** (3 ** 2)` = 512.
- A unary operator directly before `**` is a **SyntaxError**: `-2 ** 2`, `!x ** 2`,
  `2 ** -2 ** 2`. Parenthesise instead: `(-2) ** 2`. A unary operand on the *right* is fine:
  `2 ** -2`.
- `1 < 2 < 3` is legal (left-associative).

Nesting deeper than `Limits.max_nesting_depth` (default 512, counting both parentheses and
operator chains) → `LimitExceeded(nesting_depth)`.

## 5. Semantics

Nothing executes yet (M1 builds the AST only). Runtime semantics are added from M3; every
addition goes here, with its differential tests.
