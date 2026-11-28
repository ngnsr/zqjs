# ZQJS Performance Baseline

## Environment & Pinning
- **Date (UTC):** 2026-11-28T12:25:19Z
- **Host:** Darwin arm64 (macOS-15.8.3-arm64-arm-64bit)
- **Power:** Now drawing from 'Battery Power' | lowpowermode         0
- **Zig:** `0.17.1` (`-Doptimize=ReleaseFast`, `smp_allocator`)
- **QuickJS CLI:** `/opt/homebrew/bin/qjs` — `QuickJS version 2026-06-04` (SHA-256: `2b189d0001afc5447329693dbaa8d23c790ab3f44d3f65fe6476ccf2b9559847`)
- **Protocol:** 2 warm-up + 11 alternating measured runs per CLI benchmark; 30x3,600 runs for C frame loop

## 1. Normalized Correctness Parity
| Benchmark | Rule | ZQJS | QuickJS | Node (ref) |
|---|---|---|---|---|
| `arrays.js` | `exact_int` | `49999800` | `49999800` | `49999800` |
| `branch_dense.js` | `exact_int` | `776280958` | `776280958` | `776280958` |
| `call_chain.js` | `exact_int` | `74998997` | `74998997` | `74998997` |
| `closures.js` | `exact_int` | `51500000` | `51500000` | `51500000` |
| `fib.js` | `exact_int` | `514229` | `514229` | `514229` |
| `float_math.js` | `float_finite_exact` | `379494.96686201746` | `379494.96686201746` | `379494.96686201746` |
| `global_reads.js` | `exact_int` | `19999991` | `19999991` | `19999991` |
| `int_loop.js` | `exact_int` | `993972011` | `993972011` | `993972011` |
| `objects.js` | `exact_int` | `6100000` | `6100000` | `6100000` |
| `scopes.js` | `exact_int` | `38999982` | `38999982` | `38999982` |
| `strings.js` | `exact_int` | `1278890` | `1278890` | `1278890` |

## 2. CLI-to-CLI End-to-End Comparison (Startup + Parse + Compile + Run)
| Benchmark | ZQJS med (ms) | ZQJS [min, max] | QuickJS med (ms) | QuickJS [min, max] | Ratio (`zqjs/qjs`) | ZQJS RSS (KiB) | QuickJS RSS (KiB) |
|---|---:|---|---:|---|---:|---:|---:|
| `arrays.js` | 132.45 | [131.46, 136.30] | 164.01 | [161.82, 167.31] | **0.81x** | 3904 | 1808 |
| `branch_dense.js` | 56.14 | [55.38, 57.37] | 102.88 | [98.99, 105.44] | **0.55x** | 2880 | 1776 |
| `call_chain.js` | 61.61 | [60.72, 63.98] | 50.45 | [49.49, 51.85] | **1.22x** | 3088 | 1792 |
| `closures.js` | 44.99 | [44.15, 45.93] | 120.57 | [118.86, 130.37] | **0.37x** | 3376 | 1808 |
| `fib.js` | 25.83 | [25.53, 27.06] | 32.65 | [31.41, 33.14] | **0.79x** | 3072 | 1776 |
| `float_math.js` | 91.01 | [90.80, 92.89] | 133.04 | [131.23, 136.51] | **0.68x** | 2784 | 1776 |
| `global_reads.js` | 22.69 | [22.31, 22.98] | 24.20 | [24.03, 24.86] | **0.94x** | 2848 | 1792 |
| `int_loop.js` | 43.49 | [43.17, 43.91] | 68.45 | [66.75, 70.10] | **0.64x** | 2896 | 1776 |
| `objects.js` | 27.21 | [26.89, 27.39] | 31.49 | [31.02, 32.58] | **0.86x** | 3808 | 1792 |
| `scopes.js` | 24.75 | [24.29, 25.45] | 34.59 | [34.10, 35.22] | **0.72x** | 2816 | 1792 |
| `strings.js` | 8.09 | [7.97, 8.41] | 11.27 | [11.10, 11.46] | **0.72x** | 3072 | 1776 |

## 3. ZQJS Split-Phase & GC Benchmarks (`zig build bench-js -- --gc`)
```text
# bench-js: zig 0.17.1, aarch64-macos (apple_m4), fast, warmups=2, measured=11, smp_allocator
program	steps	allocated	peak	end	gc(m/M)	compile_med_ms	compile_min_ms	compile_max_ms	exec_med_ms	exec_min_ms	exec_max_ms	total_med_ms	total_min_ms	total_max_ms
bench/suite/js/arrays.js	55800013	92094988	467088	205416	214/0	0.015	0.012	0.031	130.025	129.447	130.860	130.055	129.481	130.888
bench/suite/js/branch_dense.js	23801249	862	862	862	0/0	0.014	0.013	0.037	53.956	53.200	64.066	53.973	53.238	64.110
bench/suite/js/call_chain.js	21000018	1736	1624	1624	0/0	0.012	0.009	0.029	42.934	42.176	43.415	42.952	42.188	43.430
bench/suite/js/closures.js	18000015	92001568	327872	297328	350/0	0.018	0.010	0.034	41.254	40.692	43.047	41.288	40.722	43.105
bench/suite/js/fib.js	9984482	806	806	806	0/0	0.004	0.004	0.006	23.243	23.201	23.356	23.250	23.210	23.365
bench/suite/js/float_math.js	46000020	1298	1186	1186	0/0	0.014	0.010	0.027	87.914	86.879	89.053	87.943	86.892	89.072
bench/suite/js/global_reads.js	11000022	874	874	874	0/0	0.006	0.006	0.010	20.451	20.308	20.941	20.459	20.317	20.950
bench/suite/js/int_loop.js	22000011	618	618	618	0/0	0.006	0.006	0.020	40.108	38.056	41.854	40.116	38.079	41.861
bench/suite/js/objects.js	7600020	40096384	379372	349972	152/0	0.012	0.012	0.013	24.514	24.252	24.836	24.538	24.276	24.861
bench/suite/js/scopes.js	12000013	622	622	622	0/0	0.007	0.006	0.009	22.653	22.355	23.375	22.662	22.363	23.384
bench/suite/js/strings.js	1400013	42714350	286696	253906	162/0	0.005	0.005	0.006	6.354	6.301	6.550	6.366	6.313	6.562
bench/gc/game_100k.js	27002127	394254510	34904672	34827272	1488/3	0.030	0.029	0.040	106.392	105.426	109.175	107.598	106.602	110.474
bench/gc/game_1m.js	26400727	494036778	344713900	344636426	1726/5	0.030	0.028	0.039	165.347	162.221	168.778	177.058	173.458	181.197
bench/gc/game_big_container.js	23402227	360279004	210956464	210718610	1217/4	0.035	0.031	0.049	110.040	109.370	110.830	117.862	117.169	119.162
bench/gc/game_big_dictionary.js	28606327	570893142	82929834	82821544	2029/4	0.037	0.034	0.046	197.983	194.302	215.427	202.518	198.776	220.350
bench/gc/game_growing.js	31503324	470638762	103780684	103715026	1745/5	0.031	0.029	0.052	132.476	131.568	134.127	136.376	135.351	138.027
```

## 4. ZQJS C-ABI Embedding Benchmarks (`zig build bench-c`, separate from QuickJS)
```text
js_to_c_native	runs=11	calls=1000000	med_ms=119.162	min_ms=117.108	max_ms=134.834	ns_per_call=119.2	calls_per_sec=8391937
host_js_c_js_roundtrip	runs=11	trips=100000	med_ms=29.233	min_ms=28.022	max_ms=30.011	ns_per_call=292.3	calls_per_sec=3420792
frame_loop_3600	runs=30	frames_per_run=3600	run_med_ms=62.354	run_p95_ms=63.082	run_min_ms=61.866	run_max_ms=67.834	frame_p50_us=17.00	frame_p95_us=19.00	frame_max_us=95.00	outlier_run=16	outlier_frame=2266	outlier_cpu_us=73.67	heap_bytes=274784	handle_bytes=384	gc_minor=21	gc_major=1	max_gc_pause_us=24.00
```

## 5. Individual CLI Sample Timings (ms, alternating order)
- **`arrays.js`** (`zqjs->qjs`, alternating): zqjs=[132.45, 131.46, 131.47, 132.73, 132.45, 133.31, 131.94, 136.30, 133.00, 131.67, 132.96] | qjs=[163.57, 161.82, 164.16, 163.51, 164.99, 167.31, 164.01, 166.31, 164.19, 162.42, 163.48]
- **`branch_dense.js`** (`zqjs->qjs`, alternating): zqjs=[56.06, 56.14, 55.38, 55.62, 56.01, 56.14, 57.37, 57.04, 56.51, 56.21, 55.69] | qjs=[102.88, 102.55, 98.99, 105.44, 104.07, 102.67, 103.48, 101.93, 104.24, 99.60, 103.05]
- **`call_chain.js`** (`zqjs->qjs`, alternating): zqjs=[60.83, 62.52, 60.72, 61.36, 63.98, 61.73, 63.42, 61.32, 61.61, 60.99, 62.07] | qjs=[50.45, 50.54, 51.21, 51.85, 50.05, 50.40, 50.70, 49.66, 49.49, 51.02, 50.29]
- **`closures.js`** (`zqjs->qjs`, alternating): zqjs=[44.67, 45.71, 44.15, 45.26, 45.93, 44.99, 44.20, 44.34, 44.41, 45.91, 45.24] | qjs=[120.37, 120.57, 118.86, 122.64, 123.41, 120.30, 120.37, 118.88, 121.10, 122.15, 130.37]
- **`fib.js`** (`zqjs->qjs`, alternating): zqjs=[25.66, 25.53, 26.87, 25.91, 25.82, 25.82, 25.95, 25.83, 25.83, 27.06, 25.90] | qjs=[32.72, 31.41, 32.58, 32.44, 33.14, 32.65, 33.06, 33.01, 32.75, 32.65, 32.52]
- **`float_math.js`** (`zqjs->qjs`, alternating): zqjs=[90.93, 91.63, 90.80, 91.00, 91.52, 92.89, 90.95, 91.01, 90.94, 92.09, 91.25] | qjs=[131.99, 133.04, 132.45, 134.62, 133.32, 133.55, 133.00, 134.16, 132.33, 131.23, 136.51]
- **`global_reads.js`** (`zqjs->qjs`, alternating): zqjs=[22.74, 22.71, 22.69, 22.59, 22.76, 22.32, 22.67, 22.31, 22.98, 22.41, 22.71] | qjs=[24.86, 24.12, 24.03, 24.12, 24.23, 24.04, 24.20, 24.06, 24.30, 24.65, 24.84]
- **`int_loop.js`** (`zqjs->qjs`, alternating): zqjs=[43.17, 43.91, 43.47, 43.57, 43.36, 43.49, 43.44, 43.54, 43.37, 43.56, 43.52] | qjs=[68.30, 66.75, 68.54, 68.43, 70.10, 68.73, 69.62, 67.29, 66.88, 68.69, 68.45]
- **`objects.js`** (`zqjs->qjs`, alternating): zqjs=[27.32, 27.29, 27.21, 27.39, 26.89, 27.39, 26.91, 26.89, 26.91, 26.89, 27.26] | qjs=[31.27, 31.44, 32.09, 32.03, 32.09, 31.49, 31.45, 32.58, 31.57, 31.02, 31.28]
- **`scopes.js`** (`zqjs->qjs`, alternating): zqjs=[24.72, 24.54, 24.29, 24.66, 24.56, 25.45, 25.11, 24.77, 24.75, 24.86, 25.40] | qjs=[35.22, 34.10, 34.16, 34.34, 35.07, 34.40, 34.59, 35.08, 34.18, 34.89, 34.96]
- **`strings.js`** (`zqjs->qjs`, alternating): zqjs=[8.38, 7.97, 7.98, 8.26, 8.00, 8.09, 8.11, 8.41, 8.18, 8.06, 8.06] | qjs=[11.10, 11.10, 11.25, 11.10, 11.46, 11.37, 11.17, 11.28, 11.40, 11.29, 11.27]
