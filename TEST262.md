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

## Results (M69 — `99.32%` Applicable, `90.79%` Executed, `36,062` PASS, `0` Parse / Internal Errors)

Measured at `8bb9a44` with `zig build cli -Doptimize=ReleaseFast`, `--engine=vm`, `--mode=nonstrict`:

| Suite | Collected | Skipped (meta) | Executed | Unsupported | Limit | Applicable | Pass | Fail | Pass / Executed | Pass / Applicable |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `built-ins` | 23,885 | 7,029 | 16,856 | 1,240 | 29 | 15,587 | **15,409** | 178 | **91.42%** | **98.86%** |
| `language` | 23,832 | 968 | 22,864 | 2,140 | 1 | 20,723 | **20,653** | 70 | **90.33%** | **99.66%** |
| **Combined** | **47,717** | **7,997** | **39,720** | **3,380** | **30** | **36,310** | **36,062** | **248** | **90.79%** | **99.32%** |

- **0 parse failures**, **0 internal errors** (`exit=70` / crashes), and **0 timeouts** across all 39,720 executed tests.
- Of the 248 remaining failures, **173** are `$262.createRealm` (`167`) / `$262.evalScript` (`6`) host-hook stubs — leaving only **75 real spec failures** (`30` in `built-ins`, `45` in `language`) across the entire 39,720-test run.
- Building on M68 (`36,018` PASS, `317` FAIL / `144` real), M69 landed Wave 2 conformance & runtime fixes — ES2025 §10.4.6 Module Namespace exotic internal methods (`module-code/namespace` `38/38` and `dynamic-import/namespace` `67/67`, 100%), spec `PromiseResolve` / `AsyncGeneratorPrototype.return` (`48/48`, 100%) / `AsyncFromSyncIteratorPrototype` (`38/38`, 100%) / `for-await-of` (`1,225/1,225`, 100%), dedicated `StringIteratorPrototype` & `RegExpStringIteratorPrototype` (100%) + detached `ArrayIteratorPrototype` (`27/27`, 100%), script-level `var` bindings on `globalThis` (`.define_global_var`, unlocking `global` `19/19` and `Array.from` tail), `TypedArray` (`1,213/1,213`, 100%), `Array.length` set coercion order, `--preload` diagnostic & custom thrown-error formatting, and parser/resolver edge cases (`fn-name-lhs-cover`, `static-init` `await`, `scope-var-open`, `early-import-{arguments,eval}`) — adding **+44** net passes (`36,018 → 36,062`, **99.32%** Pass / Applicable, **90.79%** Pass / Executed) and cutting real failures almost in half (`144 → 75`, **-47.9%**).

### Built-ins Breakdown (Applicable Tests)

- **100.0% (25 suites):** `ArrayIteratorPrototype` (27/27), `AsyncFromSyncIteratorPrototype` (38/38), `AsyncFunction` (5/5), `AsyncGeneratorPrototype` (48/48), `AsyncIteratorPrototype` (4/4), `GeneratorPrototype` (61/61), `Infinity` (5/5), `MapIteratorPrototype` (11/11), `Math` (317/317), `NaN` (5/5), `Reflect` (152/152), `RegExpStringIteratorPrototype` (17/17), `SetIteratorPrototype` (11/11), `StringIteratorPrototype` (7/7), `TypedArray` (1,213/1,213), `decodeURI` (54/54), `decodeURIComponent` (55/55), `encodeURI` (30/30), `encodeURIComponent` (30/30), `global` (19/19), `isFinite` (15/15), `isNaN` (15/15), `parseFloat` (54/54), `parseInt` (55/55), `undefined` (6/6).
- **99.0–99.9%:** `Promise` (631/632, 99.8%), `Iterator` (401/402, 99.8%), `String` (1,118/1,121, 99.7%), `Number` (332/333, 99.7%), `Set` (290/291, 99.7%), `DataView` (478/480, 99.6%), `Date` (599/602, 99.5%), `Array` (2,683/2,699, 99.4%), `RegExp` (1,504/1,515, 99.3%), `Map` (127/128, 99.2%), `Object` (3,081/3,109, 99.1%).
- **90.0–98.9%:** `WeakMap` (90/91, 98.9%), `ArrayBuffer` (78/79, 98.7%), `WeakSet` (77/78, 98.7%), `BigInt` (75/76, 98.7%), `JSON` (138/140, 98.6%), `Boolean` (46/47, 97.9%), `TypedArrayConstructors` (645/667, 96.7%), `AggregateError` (22/23, 95.7%), `Function` (243/256, 94.9%), `NativeErrors` (80/86, 93.0%), `ThrowTypeError` (13/14, 92.9%), `Error` (63/68, 92.6%).
- **< 90% (primarily `$262.createRealm`):** `Proxy` (261/298, 87.6% — 36 `createRealm`), `Symbol` (74/89, 83.1% — 15 `createRealm`), `AsyncGeneratorFunction` (3/4, 75.0%), `GeneratorFunction` (3/4, 75.0%), `eval` (0/1, 0.0%).

---

## Remaining Spec Edge Cases for Future Improvements

### Host Test Hooks (173 of 248 failures)
1. **`$262.createRealm` (167) & `$262.evalScript` (6)**: cross-realm prototype checks (`proto-from-ctor-realm`) and `evalScript` host hooks are not implemented in the CLI stub (5 additional `language/global-code/script-decl-*` tests also expect `evalScript` to throw `SyntaxError`/`TypeError` rather than `Error`).

### Runtime & Built-ins (30 real failures + `defineProperty` on array indices)
2. **Intentionally excluded / unimplemented (`27` of `30`):** Annex B `Object.prototype.{__defineGetter__,__defineSetter__,__lookupGetter__,__lookupSetter__,__proto__}` (15, D39/D69), mapped `arguments` `defineProperty` (6), unimplemented `eval`/`toLocaleString`/`localeCompare`/`Function.prototype.toString` descriptors (6).
3. **Remaining real built-in items (`3`):** `Proxy/set/call-parameters-prototype-index.js` (VM `fastArraySet` hole check), `DataView.prototype.byteLength` detached (1, matches Node 26 `TypeError` vs ES2026 `0`), `eval/prop-desc.js` (1).
4. **Array-index `defineProperty` (`Unsupported` cluster):** `410` `Unsupported(builtin): defineProperty` hits on array indices (lazy per-index descriptor overrides can unlock +300–400 passes).

### Language (45 real failures)
5. **`language/arguments-object` + mapped aliasing (`32` of `45`):** sloppy-mode mapped `arguments` (`[[ParameterMap]]`, 21 in `mapped/*`, 8 legacy `10.6-*`/`S10.6_*`, plus 3 in `async-function`/`for-of`/`yield`).
6. **Stage-1 / host stub (`7` of `45`):** `nonextensible-applies-to-private` Stage-1 proposal (2) and `script-decl-*` `evalScript` stub error types (5).
7. **Remaining real language tail (`6`):** `global-code/decl-func.js`, `statements/function/S13.2.2_A1_T{1,2}` & `S13_A15_T4`, `expressions/delete/11.4.1-4.a-11`, `identifier-resolution/assign-to-global-undefined`.
