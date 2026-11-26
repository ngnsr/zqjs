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

## Results (M68 — `99.13%` Applicable, `90.68%` Executed, `36,018` PASS, `0` Internal Errors)

Measured at `238babd` with `zig build cli -Doptimize=ReleaseFast`, `--engine=vm`, `--mode=nonstrict`:

| Suite | Collected | Skipped (meta) | Executed | Unsupported | Limit | Applicable | Pass | Fail | Pass / Executed | Pass / Applicable |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `built-ins` | 23,885 | 7,029 | 16,856 | 1,240 | 28 | 15,588 | **15,390** | 198 | **91.30%** | **98.73%** |
| `language` | 23,832 | 968 | 22,864 | 2,116 | 1 | 20,747 | **20,628** | 119 | **90.22%** | **99.43%** |
| **Combined** | **47,717** | **7,997** | **39,720** | **3,356** | **29** | **36,335** | **36,018** | **317** | **90.68%** | **99.13%** |

- **0 internal errors** (`exit=70` / crashes) and **0 timeouts** across all 39,720 executed tests.
- Of the 317 remaining failures, **173** are `$262.createRealm` (`167`) / `$262.evalScript` (`6`) host-hook stubs — leaving only **144 real spec failures** (`50` in `built-ins`, `94` in `language`) across the entire 39,720-test run.
- Building on M67 (`35,188` PASS, `577` FAIL), M68 landed 11 conformance & runtime waves — materialized global `prop-desc` + complete `Math` (`317/317`, 100%), `Promise`/`Function`/`Symbol` conformance, `Date` sub-minute LMT timezone offsets + `JSON.stringify` GC rooting, ES2025 cyclic module/TLA evaluation + `--preload`, `language/expressions` (`ToPropertyKey` once, `SetFunctionName`, `super` null-proto, frozen tagged templates, optional-chaining `this`), `for-of`/`for-in` head grammar, `RegExp` Unicode 17.0 property-escape tables (`100%`), `TypedArray` callable iterables & `DataView` detached `byteOffset`, incompatible array/regexp/iterator receiver checks, and allocation-free custom thrown error formatting (`line-terminators` `32/32`, 100%) — unlocking **+830** net passes (`35,188 → 36,018`, **99.13%** Pass / Applicable, **90.68%** Pass / Executed, failures cut **-45.1%** from `577 → 317`).

### Built-ins Breakdown (Applicable Tests)

- **100.0%:** `AsyncFunction` (5/5), `AsyncIteratorPrototype` (4/4), `GeneratorPrototype` (61/61), `Infinity` (5/5), `MapIteratorPrototype` (11/11), `Math` (317/317), `NaN` (5/5), `Reflect` (152/152), `SetIteratorPrototype` (11/11), `decodeURI` (54/54), `decodeURIComponent` (55/55), `encodeURI` (30/30), `encodeURIComponent` (30/30), `isFinite` (15/15), `isNaN` (15/15), `parseFloat` (54/54), `parseInt` (55/55), `undefined` (6/6).
- **99.0–99.9%:** `TypedArray` (1,212/1,213, 99.9%), `Promise` (631/632, 99.8%), `Iterator` (401/402, 99.8%), `Number` (332/333, 99.7%), `String` (1,117/1,121, 99.6%), `DataView` (478/480, 99.6%), `Date` (599/602, 99.5%), `Set` (289/291, 99.3%), `Array` (2,680/2,699, 99.3%), `RegExp` (1,505/1,516, 99.3%), `Map` (127/128, 99.2%), `Object` (3,080/3,109, 99.1%).
- **90.0–98.9%:** `WeakMap` (90/91, 98.9%), `ArrayBuffer` (78/79, 98.7%), `WeakSet` (77/78, 98.7%), `BigInt` (75/76, 98.7%), `JSON` (138/140, 98.6%), `Boolean` (46/47, 97.9%), `TypedArrayConstructors` (644/667, 96.6%), `ArrayIteratorPrototype` (26/27, 96.3%), `AggregateError` (22/23, 95.7%), `Function` (243/256, 94.9%), `global` (18/19, 94.7%), `AsyncGeneratorPrototype` (45/48, 93.8%), `NativeErrors` (80/86, 93.0%), `ThrowTypeError` (13/14, 92.9%), `Error` (63/68, 92.6%), `AsyncFromSyncIteratorPrototype` (35/38, 92.1%).
- **< 90% (primarily `$262.createRealm`):** `RegExpStringIteratorPrototype` (15/17, 88.2%), `Proxy` (261/298, 87.6% — 36 `createRealm`), `Symbol` (74/89, 83.1% — 15 `createRealm`), `GeneratorFunction` (3/4, 75.0%), `AsyncGeneratorFunction` (3/4, 75.0%), `StringIteratorPrototype` (5/7, 71.4%), `eval` (0/1, 0.0%).

---

## Remaining Spec Edge Cases for Future Improvements

### Host Test Hooks (173 of 317 failures)
1. **`$262.createRealm` (167) & `$262.evalScript` (6)**: cross-realm prototype checks (`proto-from-ctor-realm`) and `evalScript` host hooks are not implemented in the CLI stub.

### Runtime & Built-ins (50 real failures + `defineProperty` on array indices)
2. **`Object.defineProperty` / `getOwnPropertyDescriptor` & Annex B (`built-ins/Object`, 28 fails)**: array-element descriptor overrides (`410` `Unsupported(builtin): defineProperty` in `built-ins/`), non-configurable property edge cases, and intentionally excluded Annex B `__defineGetter__`/`__lookupGetter__`/`__proto__`.
3. **`AsyncGeneratorPrototype.return` (3) & `AsyncFromSyncIteratorPrototype` (3)**: broken-promise / poisoned-wrapper rejection edge cases.
4. **Tail built-ins (~16 fails total)**: `Array.from`/`length` coercion (3), `RegExpStringIteratorPrototype`/`StringIteratorPrototype` (4), `TypedArrayConstructors/internals/Set` OOB receiver (1), `DataView.prototype.byteLength` detached (1, matches Node 26 `TypeError` vs ES2026 `0`).

### Language & Modules (94 real failures)
5. **`language/module-code` (30 fails)**: module namespace exotic internal methods (`define-own-property`, `delete-non-exported`, `has-property-str-found-uninit`) and remaining cyclic/live-binding edge cases.
6. **`language/arguments-object` (29 fails)**: sloppy-mode mapped `arguments` aliasing (`21` tests; ZQJS currently implements unmapped `arguments`).
7. **`language/statements` (13), `language/expressions` (12), `language/global-code` (8)**: remaining `for-await-of` microtask tick ordering, parser `fn-name-lhs-cover`, private fields on non-extensible return-override objects, and sloppy global `var`/function declaration re-declaration rules.
