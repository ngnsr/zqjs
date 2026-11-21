# Test262 Conformance

ZQJS includes a parallel [tc39/test262](https://github.com/tc39/test262) conformance runner in [tools/test262.py](tools/test262.py) (Python 3 standard library only).

## Running Test262

1. Clone Test262 (shallow clone is ~57k files, ~35s):
   ```sh
   git clone --depth 1 https://github.com/tc39/test262.git /tmp/test262
   ```
2. Build `zqjs` in `ReleaseFast` (Debug builds are ~10× slower per process):
   ```sh
   zig build -Doptimize=ReleaseFast
   ```
3. Run a suite or the full `built-ins` / `language` trees:
   ```sh
   python3 tools/test262.py built-ins/BigInt
   python3 tools/test262.py built-ins --json /tmp/t262_builtins.json --show-failures 30
   python3 tools/test262.py language --json /tmp/t262_language.json --show-failures 30
   ```

### Useful Options
- `--test262-dir PATH` — path to `tc39/test262` checkout (default `/tmp/test262`)
- `--zqjs PATH` — path to `zqjs` binary (default `./zig-out/bin/zqjs`)
- `--engine=vm|treewalk` — engine to test (default `vm`)
- `--mode=nonstrict|strict` — execution mode (default `nonstrict`; `onlyStrict` tests still run in strict mode)
- `--jobs N` / `-j N` — parallel worker count (default `os.cpu_count()`)
- `--max-steps N` — step budget per test (default `5000000`)
- `--timeout SEC` — per-test timeout in seconds (default `5.0`)
- `--show-failures N` — print up to `N` real failures (default `20`)
- `--json PATH` — write per-test JSON report
- `--no-skip-features` — disable skipping out-of-scope feature tags (`Intl.*`, `Temporal`, `Atomics`, `SharedArrayBuffer`, `ShadowRealm`, `WeakRef`, `FinalizationRegistry`, `IsHTMLDDA`, etc.)

## How the Runner Works

- **Harness shim:** Test262's `harness/sta.js`, `harness/assert.js`, and helper includes use `var`. Because ZQJS intentionally rejects `var` as `Unsupported(syntax)`, the runner rewrites `\bvar\b` → `let` in `harness/*.js` only and provides a minimal `$262` host stub (`global: {}`, `gc: () => {}`). Test files themselves are executed **unmodified**.
- **Outcome classification:**
  - `pass`: test matched its expected outcome (including `negative` parse/runtime error types and `async` `$DONE` completion).
  - `unsupported`: `zqjs` emitted `Unsupported(<feature>)` (intentional ZQJS restrictions such as `var`, `asi`, `loose_equality`, `arguments`, `sloppy_this`, or unimplemented built-ins).
  - `applicable`: `executed - unsupported - limit` — tests that ZQJS accepted and ran to completion/error.
  - `fail_assert` / `fail_runtime` / `fail_parse`: real spec or edge-case mismatches on applicable tests.
  - `internal`: exit code 70 (bytecode verifier rejection) or process crash.

---

## Baseline Results (M47, `3894732`)

Measured with `zig build -Doptimize=ReleaseFast`, `--engine=vm`, `--mode=nonstrict`:

| Suite | Collected | Skipped (meta) | Executed | Unsupported | Limit | Applicable | Pass | Fail | Pass / Executed | Pass / Applicable |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `built-ins` | 23,885 | 7,150 | 16,735 | 14,743 | 1 | 1,991 | 1,826 | 165 | 10.91% | **91.71%** |
| `language` | 23,832 | 764 | 23,068 | 19,292 | 0 | 3,776 | 3,230 | 546 | 14.00% | **85.54%** |
| **Combined** | **47,717** | **7,914** | **39,803** | **34,035** | **1** | **5,767** | **5,056** | **711** | **12.70%** | **87.67%** |

- **0 internal errors** (`exit=70` / crashes) across all 39,803 executed tests.
- Top `Unsupported` causes in unmodified Test262 files: `syntax` (mostly `var`: 25,606), `arguments` (4,352), `builtin` (1,866), `asi` (1,048), `sloppy_this` (396), `block_function` (156), `global_assignment` (146), `loose_equality` (109).

### Built-ins Breakdown (Applicable Tests)

- **100.0%:** `AggregateError` (3/3), `ArrayBuffer` (13/13), `AsyncFromSyncIteratorPrototype` (1/1), `AsyncFunction` (1/1), `BigInt` (29/29), `Error` (15/15), `GeneratorPrototype` (3/3), `Infinity` (1/1), `NaN` (1/1), `NativeErrors` (36/36), `Proxy` (17/17), `Reflect` (40/40), `WeakMap` (14/14), `WeakSet` (12/12), `global` (4/4), `isFinite` (6/6), `isNaN` (6/6), `parseFloat` (45/45), `parseInt` (34/34).
- **90–99%:** `RegExp` (295/305, 96.7%), `Object` (249/258, 96.5%), `Array` (190/197, 96.4%), `DataView` (27/28, 96.4%), `JSON` (47/49, 95.9%), `String` (206/216, 95.4%), `Math` (118/125, 94.4%), `Map` (25/27, 92.6%), `Number` (113/122, 92.6%), `decodeURI` (10/11, 90.9%), `decodeURIComponent` (11/12, 91.7%).
- **< 90%:** `TypedArrayConstructors` (33/37, 89.2%), `Set` (16/18, 88.9%), `encodeURI` (8/9, 88.9%), `encodeURIComponent` (8/9, 88.9%), `Symbol` (13/16, 81.2%), `Function` (38/47, 80.9%), `Promise` (132/176, 75.0%), `TypedArray` (1/4, 25.0%), `Iterator` (5/44, 11.4% — mostly Stage 2/3 `Iterator.prototype.chunks` / `includes`).

---

## Spec Edge Cases for Future Improvements

### Runtime & Built-ins
1. **`Array.from` on array-like objects** (`built-ins/Array/from/array-like-has-length-but-no-indexes-with-values.js`): throws `TypeError: value is not iterable` when `[Symbol.iterator]` is absent instead of falling back to `ToLength(arrayLike.length)`.
2. **`Function.prototype.apply(thisArg, null | undefined)`** (`built-ins/Function/prototype/apply/15.3.4.3-1-s.js`..`3-s.js`): throws `TypeError: CreateListFromArrayLike called on non-object` instead of treating `null`/`undefined` `argArray` as `[]`.
3. **`Promise.any` / `Promise.race` / `Promise.all` abrupt completion & iterator closing** (`built-ins/Promise/any/capability-resolve-throws-no-close.js`, `capability-resolve-throws-reject.js`): capability `resolve` throwing and iterator-close ordering edge cases.
4. **Built-in method `.length` and property descriptors**:
   - `String.prototype.{charAt,charCodeAt,includes,indexOf,lastIndexOf,search}` (`S15.5.4.*_A11.js`)
   - `Number.prototype` (`S15.7.4_A3.1.js`..`A3.5.js`)
   - `Array.isArray` (`15.4.3.2-0-2.js`, `15.4.3.2-0-5.js`), `Array.of`, `Array.prototype.length` (`define-own-prop-length-error.js`)
   - `Object.create` (`properties-arg-to-object-non-empty-string.js`), `Object.freeze` (`throws-when-false.js`), `Object.getPrototypeOf`, `Object.keys`
5. **`TypedArray.from`** (`built-ins/TypedArray/from/*`): throws `TypeError: TypedArray.from requires a TypedArray constructor` on valid `TypedArray` subclasses / `this` bindings.
6. **`RegExp` named capture groups**: `built-ins/RegExp/named-groups/non-unicode-property-names.js` (`SyntaxError: invalid capture group name`).

### Parser & Static Semantics (`language`)
7. **`"use strict";` directive with non-simple parameter lists**: `language/expressions/arrow-function/array-destructuring-param-strict-body.js`, `rest-param-strict-body.js` (and `function` / `async` equivalents) are not rejected with an early `SyntaxError`.
8. **Strict-mode class identifier restrictions**: `language/statements/class/class-name-ident-static.js`, `class-name-ident-yield.js` are not rejected with an early `SyntaxError`.
9. **Escaped keywords as class method names**: `language/statements/class/ident-name-method-def-break-escaped.js`, `ident-name-method-def-case-escaped.js` fail with `SyntaxError: expected ';' after class field`.
10. **`super[expr]` before `super()`**: `language/expressions/super/prop-expr-uninitialized-this-*.js`.
11. **Runner / harness gaps** (not ZQJS bugs):
    - Module tests using `assert` (`language/module-code/namespace/*`, `language/eval-code/*/export.js`) fail with `ReferenceError: assert is not defined` because `tools/test262.py` does not prepend harness files to `--module` tests.
    - Stage 2/3 proposals not yet tagged in `DEFAULT_SKIP_FEATURES`: `language/import/import-defer/*` (79), `built-ins/Iterator/prototype/{chunks,includes}` (~39), `built-ins/Math/sumPrecise/*` (5), `built-ins/Promise/{allKeyed,allSettledKeyed}/*` (6).
