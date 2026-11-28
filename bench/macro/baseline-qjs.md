# ZQJS Macro Performance Baseline

## Environment & Pinning
- **Date (UTC):** 2026-11-28T12:22:08Z
- **Host:** Darwin arm64 (macOS-15.8.3-arm64-arm-64bit)
- **Power:** Now drawing from 'Battery Power' | lowpowermode         0
- **Zig:** `0.17.1` (`-Doptimize=ReleaseFast`, `smp_allocator`)
- **QuickJS CLI:** `/opt/homebrew/bin/qjs` — `QuickJS version 2026-06-04` (SHA-256: `2b189d0001afc5447329693dbaa8d23c790ab3f44d3f65fe6476ccf2b9559847`)
- **Protocol:** 2 warm-up + 11 alternating measured runs per CLI benchmark

## 1. Normalized Correctness Parity
| Benchmark | Rule | ZQJS | QuickJS | Node (ref) |
|---|---|---|---|---|
| `expr_eval.js` | `exact_int` | `4276956510` | `4276956510` | `4276956510` |
| `json_roundtrip.js` | `exact_int` | `2762838859` | `2762838859` | `2762838859` |
| `physics_tick.js` | `exact_int` | `2434733654` | `2434733654` | `2434733654` |
| `schema_validate.js` | `exact_int` | `884446005` | `884446005` | `884446005` |
| `template_render.js` | `exact_int` | `2475627009` | `2475627009` | `2475627009` |

## 2. CLI-to-CLI End-to-End Comparison (Startup + Parse + Compile + Run)
| Benchmark | ZQJS med (ms) | ZQJS [min, max] | QuickJS med (ms) | QuickJS [min, max] | Ratio (`zqjs/qjs`) | ZQJS RSS (KiB) | QuickJS RSS (KiB) |
|---|---:|---|---:|---|---:|---:|---:|
| `expr_eval.js` | 132.65 | [131.59, 135.60] | 128.17 | [126.43, 131.00] | **1.03x** | 4496 | 2016 |
| `json_roundtrip.js` | 151.04 | [150.46, 154.14] | 188.41 | [187.27, 190.02] | **0.80x** | 5760 | 2000 |
| `physics_tick.js` | 138.36 | [137.46, 141.05] | 112.46 | [111.12, 113.81] | **1.23x** | 5072 | 1936 |
| `schema_validate.js` | 199.31 | [198.19, 204.64] | 190.66 | [189.99, 192.25] | **1.05x** | 4448 | 1904 |
| `template_render.js` | 128.13 | [126.39, 133.33] | 108.41 | [107.06, 110.74] | **1.18x** | 9392 | 2016 |

## 3. Individual CLI Sample Timings (ms, alternating order)
- **`expr_eval.js`** (`zqjs->qjs`, alternating): zqjs=[133.12, 132.80, 133.08, 133.12, 135.60, 131.80, 132.49, 131.59, 132.27, 132.65, 131.78] | qjs=[128.17, 126.43, 126.71, 126.83, 131.00, 127.61, 128.49, 128.25, 128.83, 128.14, 129.44]
- **`json_roundtrip.js`** (`zqjs->qjs`, alternating): zqjs=[151.29, 151.11, 150.46, 152.20, 150.83, 150.90, 150.62, 154.14, 151.07, 151.04, 151.03] | qjs=[188.41, 188.68, 187.27, 188.00, 187.91, 188.86, 188.26, 188.14, 190.02, 189.17, 188.58]
- **`physics_tick.js`** (`zqjs->qjs`, alternating): zqjs=[137.63, 137.68, 137.46, 138.20, 138.45, 138.18, 139.77, 141.05, 138.36, 138.75, 139.96] | qjs=[112.02, 112.69, 112.46, 111.86, 111.12, 111.87, 112.89, 112.19, 113.81, 112.69, 112.58]
- **`schema_validate.js`** (`zqjs->qjs`, alternating): zqjs=[200.11, 199.79, 199.30, 198.91, 199.31, 199.88, 198.19, 201.44, 204.64, 198.68, 199.25] | qjs=[192.25, 191.53, 190.75, 190.59, 190.66, 190.95, 190.54, 191.12, 190.55, 189.99, 190.66]
- **`template_render.js`** (`zqjs->qjs`, alternating): zqjs=[126.64, 126.79, 128.16, 128.13, 127.08, 127.66, 126.39, 133.33, 129.34, 129.47, 128.94] | qjs=[110.01, 108.03, 108.41, 107.58, 107.46, 107.06, 108.26, 110.64, 110.13, 109.66, 110.74]
