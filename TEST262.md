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

- **Harness:** Test262's `harness/sta.js`, `harness/assert.js`, and helper includes are loaded **unmodified** (with a minimal `$262` host stub: `global: {}`, `gc: () => {}`). Test files themselves are executed **unmodified**.
- **Outcome classification:**
  - `pass`: test matched its expected outcome (including `negative` parse/runtime error types and `async` `$DONE` completion).
  - `unsupported`: `zqjs` emitted `Unsupported(<feature>)` (intentional ZQJS restrictions such as `sloppy_this`, `sparse_array`, `global_assignment`, or unimplemented built-ins).
  - `applicable`: `executed - unsupported - limit` — tests that ZQJS accepted and ran to completion/error.
  - `fail_assert` / `fail_runtime` / `fail_parse`: real spec or edge-case mismatches on applicable tests.
  - `internal`: exit code 70 (bytecode verifier rejection) or process crash.

---

## Results (M63 — Unicode Identifiers, Sloppy `this` & Global Writes, Strict Mode, ES2025 Iterator Helpers, `Symbol.species`, `RegExp.escape`, `Error.isError`, Thenables, `Array.fromAsync`, `Number` Formatting)

Measured with `zig build cli -Doptimize=ReleaseFast`, `--engine=vm`, `--mode=nonstrict`:

| Suite | Collected | Skipped (meta) | Executed | Unsupported | Limit | Applicable | Pass | Fail | Pass / Executed | Pass / Applicable |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `built-ins` | 23,885 | 6,981 | 16,904 | 1,927 | 469 | 14,508 | **13,983** | 525 | **82.72%** | **96.38%** |
| `language` | 23,832 | 968 | 22,864 | 2,291 | 1 | 20,572 | **20,115** | 457 | **87.98%** | **97.78%** |
| **Combined** | **47,717** | **7,949** | **39,768** | **4,218** | **470** | **35,080** | **34,098** | **982** | **85.74%** | **97.20%** |

- **0 internal errors** (`exit=70` / crashes) and **0 timeouts** across all 39,768 executed tests.
- Building on M60 (`29,434` PASS), adding `"use strict"` directive prologue & strict property writes/`delete`, sloppy-mode `this` coercion & global writes (`globalThis`), Unicode `ID_Start`/`ID_Continue` identifiers & whitespace, `$262.detachArrayBuffer` + detached `ArrayBuffer` guards, `Symbol.{species, match, replace, search, split, matchAll, isConcatSpreadable}`, `Symbol.prototype[Symbol.toPrimitive]`, `TypedArraySpeciesCreate`/`ArraySpeciesCreate`/`ArrayBuffer.prototype.slice` species, TypedArray exotic `[[DefineOwnProperty]]`/`[[Set]]` internals, `RegExp.escape` / `RegExp.prototype` accessor getters & generic `toString`/`[Symbol.{match, search, replace, split, matchAll}]`, `Error.isError`, `String.raw` / `String.prototype.{concat, toLocaleLowerCase, toLocaleUpperCase}`, ES2025 `String.prototype.{match, matchAll, replace, search, split}` object checks & invocation, generic `String.prototype` & `Array.prototype` receivers, `TypedArray.prototype.toLocaleString`, `super` in object literal methods/accessors, `Number.prototype.{toFixed, toExponential, toPrecision}`, `Array.from`/`Array.fromAsync` custom `this` constructors, ES2025 `Iterator` helpers, ES2025 `Set` methods, `Date.prototype.set*`/generic `toJSON`/`toLocale*`, full `NewPromiseCapability`/thenable assimilation/`Promise.try`/`Promise.withResolvers`/generic `Promise.prototype.finally`, `Map.prototype.size`/`Set.prototype.size` accessors, built-in `.length` descriptors, `getAsyncIterator` abrupt completion propagation, `RequireObjectCoercible` before `ToPropertyKey`, logical assignment `NamedEvaluation`, `switch` lexical class/function redeclaration checks, classic-script dynamic `import()` filesystem resolution, and class element parser/UTF-16 field key conformance unlocked **+4,664** more passes (`29,434 → 34,098`, **97.20%** Pass / Applicable, **87.98%** `language` and **82.72%** `built-ins` Pass / Executed).

### Built-ins Breakdown (Applicable Tests)

- **100.0%:** `AggregateError` (3/3), `Array` (197/197), `ArrayBuffer` (13/13), `AsyncFromSyncIteratorPrototype` (1/1), `AsyncFunction` (1/1), `BigInt` (29/29), `Error` (15/15), `GeneratorPrototype` (3/3), `Infinity` (1/1), `JSON` (47/47), `Map` (27/27), `Math` (120/120), `NaN` (1/1), `NativeErrors` (36/36), `Object` (258/258), `Proxy` (17/17), `Reflect` (40/40), `Set` (18/18), `String` (216/216), `WeakMap` (14/14), `WeakSet` (12/12), `global` (4/4), `isFinite` (6/6), `isNaN` (6/6), `parseFloat` (45/45), `parseInt` (34/34).
- **90–99%:** `Number` (161/164, 98.2%), `RegExp` (295/301, 98.0%), `DataView` (27/28, 96.4%), `decodeURIComponent` (11/12, 91.7%), `decodeURI` (10/11, 90.9%), `Promise` (152/168, 90.5%).
- **< 90%:** `TypedArrayConstructors` (33/37, 89.2%), `encodeURI` (8/9, 88.9%), `encodeURIComponent` (8/9, 88.9%), `Function` (38/44, 86.4%), `Symbol` (13/16, 81.2%), `TypedArray` (1/4, 25.0%), `Iterator` (0/2, 0.0%).

---

## Remaining Spec Edge Cases for Future Improvements

### Runtime & Built-ins
1. **`Number.prototype.{toFixed, toExponential, toPrecision}`** (`S15.7.4_A3.5.js`..`A3.7.js`): not yet implemented.
2. **`Promise` combinators (`Object.defineProperty` on `Promise` / `C`)**: `Promise` constructor is a `.native` function, so `Object.defineProperty(Promise, "resolve", ...)` fails with `Object.defineProperty called on non-object` (`function_properties`).
3. **`Function.prototype.bind`** (`instance-length-exceeds-int32.js`, `instance-length-tointeger.js`): `length` clamping / `ToIntegerOrInfinity` edge cases.
4. **Host test hooks**: `$262.createRealm` / `$262.detachArrayBuffer` (`class-ctor-realm.js`, `detached-buffer.js`).

### Parser & Static Semantics (`language`)
5. **`dynamic-import` & self-importing module tests**: tests that self-import `./<self>.js` cannot see the harness injected into the temporary entry module without a native `--preload` flag in `zqjs`.
6. **Generator / async-generator / destructuring `yield` & `eval` early errors**: `param-dflt-yield-id-strict.js`, `early-errors-expression-binding-identifier-eval.js`, and destructuring assignment `yield` checks.
7. **Computed static `"prototype"` method on classes**: `computed-property-names/class/static/*-prototype.js` should throw `TypeError` when redefining non-configurable `C.prototype`.
8. **Unicode line terminators (`U+2028`/`U+2029`) in `for-await-of` / destructuring shorthand**: remaining `for-await-of` destructuring edge cases.
