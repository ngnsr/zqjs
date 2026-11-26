# ZQJS Performance Baseline

## Environment & Pinning
- **Date (UTC):** 2026-11-26T15:56:33Z
- **Host:** Darwin arm64 (macOS-15.8.3-arm64-arm-64bit-Mach-O)
- **Power:** Now drawing from 'AC Power' | lowpowermode         0
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
| `arrays.js` | 143.47 | [143.03, 145.09] | 164.30 | [161.64, 165.20] | **0.87x** | 3776 | 1936 |
| `branch_dense.js` | 59.89 | [59.64, 62.60] | 103.70 | [101.30, 105.62] | **0.58x** | 2816 | 1904 |
| `call_chain.js` | 46.40 | [44.02, 50.22] | 50.94 | [49.83, 51.42] | **0.91x** | 3072 | 1920 |
| `closures.js` | 44.38 | [43.98, 44.66] | 121.36 | [120.20, 123.35] | **0.37x** | 3344 | 1904 |
| `fib.js` | 25.66 | [25.51, 26.72] | 32.74 | [32.41, 33.54] | **0.78x** | 2976 | 1904 |
| `float_math.js` | 94.15 | [93.64, 94.99] | 133.12 | [132.82, 137.96] | **0.71x** | 2816 | 1904 |
| `global_reads.js` | 21.38 | [21.28, 21.64] | 24.23 | [24.12, 24.85] | **0.88x** | 2816 | 1904 |
| `int_loop.js` | 41.86 | [41.65, 42.27] | 67.85 | [64.67, 69.67] | **0.62x** | 2784 | 1904 |
| `objects.js` | 29.55 | [29.30, 31.51] | 31.94 | [30.85, 32.28] | **0.93x** | 3728 | 1920 |
| `scopes.js` | 23.84 | [23.68, 24.26] | 34.98 | [34.41, 37.56] | **0.68x** | 2800 | 1920 |
| `strings.js` | 8.57 | [8.36, 8.79] | 11.51 | [11.31, 11.85] | **0.75x** | 3024 | 1904 |

## 3. ZQJS Split-Phase & GC Benchmarks (`zig build bench-js -- --gc`)
```text
# bench-js: zig 0.17.1, aarch64-macos (apple_m4), fast, warmups=2, measured=11, smp_allocator
program	steps	allocated	peak	end	gc(m/M)	compile_med_ms	compile_min_ms	compile_max_ms	exec_med_ms	exec_min_ms	exec_max_ms	total_med_ms	total_min_ms	total_max_ms
bench/suite/js/arrays.js	55800013	91289432	457884	414124	210/0	0.015	0.013	0.023	141.913	141.260	142.802	141.937	141.283	142.835
bench/suite/js/branch_dense.js	23801249	862	862	862	0/0	0.015	0.013	0.019	57.346	57.276	57.647	57.362	57.290	57.663
bench/suite/js/call_chain.js	21000018	1736	1624	1624	0/0	0.009	0.008	0.019	44.969	44.814	45.270	44.980	44.827	45.282
bench/suite/js/closures.js	18000015	92001568	327872	297328	350/0	0.012	0.010	0.039	40.828	40.061	41.635	40.863	40.091	41.659
bench/suite/js/fib.js	9984482	806	806	806	0/0	0.004	0.004	0.007	23.246	23.217	23.627	23.252	23.223	23.633
bench/suite/js/float_math.js	46000020	1298	1186	1186	0/0	0.011	0.009	0.028	91.786	91.256	92.514	91.798	91.267	92.527
bench/suite/js/global_reads.js	11000022	874	874	874	0/0	0.006	0.006	0.007	19.281	19.191	19.473	19.289	19.199	19.480
bench/suite/js/int_loop.js	22000011	618	618	618	0/0	0.006	0.006	0.014	39.592	39.494	39.705	39.599	39.504	39.712
bench/suite/js/objects.js	7600020	38490820	371664	299472	146/0	0.013	0.012	0.020	26.472	26.269	26.804	26.498	26.292	26.826
bench/suite/js/scopes.js	12000013	622	622	622	0/0	0.006	0.006	0.006	21.509	21.109	21.639	21.516	21.115	21.646
bench/suite/js/strings.js	1400013	42714350	286696	253906	162/0	0.005	0.005	0.007	6.536	6.306	6.723	6.549	6.318	6.734
bench/gc/game_100k.js	27002127	388648946	34082108	33984500	1466/3	0.028	0.025	0.040	107.569	106.320	110.201	108.680	107.416	111.341
bench/gc/game_1m.js	26400727	484431214	336702874	336571356	1689/5	0.031	0.028	0.041	166.061	162.155	172.674	177.379	173.294	185.203
bench/gc/game_big_container.js	23402227	350672640	202944300	202921778	1178/4	0.036	0.033	0.042	112.206	110.296	114.933	120.132	118.210	123.017
bench/gc/game_big_dictionary.js	28606327	564485178	81314526	81105046	2006/4	0.038	0.035	0.044	197.074	194.008	217.845	201.616	198.672	222.547
bench/gc/game_growing.js	31503324	463433198	101093302	101036212	1718/5	0.035	0.030	0.046	144.914	142.423	146.080	148.873	146.209	149.854
```

## 4. ZQJS C-ABI Embedding Benchmarks (`zig build bench-c`, separate from QuickJS)
```text
js_to_c_native	runs=11	calls=1000000	med_ms=139.762	min_ms=129.777	max_ms=149.065	ns_per_call=139.8	calls_per_sec=7155021
host_js_c_js_roundtrip	runs=11	trips=100000	med_ms=23.340	min_ms=22.966	max_ms=25.363	ns_per_call=233.4	calls_per_sec=4284490
frame_loop_3600	runs=30	frames_per_run=3600	run_med_ms=60.914	run_p95_ms=61.456	run_min_ms=60.529	run_max_ms=61.970	frame_p50_us=17.00	frame_p95_us=18.00	frame_max_us=54.00	outlier_run=18	outlier_frame=2658	outlier_cpu_us=40.33	heap_bytes=255380	handle_bytes=384	gc_minor=20	gc_major=1	max_gc_pause_us=22.00
```

## 5. Individual CLI Sample Timings (ms, alternating order)
- **`arrays.js`** (`zqjs->qjs`, alternating): zqjs=[143.58, 145.09, 143.03, 143.35, 143.54, 143.35, 143.47, 143.35, 143.18, 143.84, 144.42] | qjs=[165.20, 164.02, 165.13, 164.79, 161.64, 163.85, 164.92, 164.30, 164.59, 163.08, 164.29]
- **`branch_dense.js`** (`zqjs->qjs`, alternating): zqjs=[59.97, 59.83, 59.76, 59.89, 59.71, 62.60, 61.43, 60.03, 59.72, 59.99, 59.64] | qjs=[103.21, 101.30, 104.28, 104.17, 103.48, 103.59, 105.28, 103.68, 103.70, 105.62, 105.01]
- **`call_chain.js`** (`zqjs->qjs`, alternating): zqjs=[48.62, 49.74, 48.91, 46.36, 50.22, 46.78, 46.40, 44.02, 45.96, 46.05, 45.88] | qjs=[51.42, 51.19, 49.89, 49.83, 51.28, 50.12, 51.02, 50.94, 50.52, 50.44, 51.31]
- **`closures.js`** (`zqjs->qjs`, alternating): zqjs=[44.46, 44.17, 44.40, 43.98, 44.44, 44.26, 44.66, 44.38, 44.41, 44.36, 44.18] | qjs=[121.04, 122.83, 123.35, 122.58, 120.20, 120.49, 122.57, 121.36, 120.35, 121.42, 120.99]
- **`fib.js`** (`zqjs->qjs`, alternating): zqjs=[25.99, 25.58, 25.56, 25.66, 25.51, 26.39, 26.72, 25.85, 25.69, 25.58, 25.63] | qjs=[33.04, 32.43, 32.58, 33.00, 32.74, 32.66, 33.21, 33.54, 32.86, 32.41, 32.62]
- **`float_math.js`** (`zqjs->qjs`, alternating): zqjs=[93.64, 94.08, 93.86, 94.99, 94.80, 93.64, 94.17, 94.15, 94.46, 93.96, 94.78] | qjs=[133.05, 133.70, 134.66, 133.00, 132.84, 132.89, 132.82, 137.96, 137.57, 134.05, 133.12]
- **`global_reads.js`** (`zqjs->qjs`, alternating): zqjs=[21.64, 21.33, 21.44, 21.34, 21.38, 21.42, 21.33, 21.36, 21.28, 21.39, 21.52] | qjs=[24.47, 24.15, 24.48, 24.19, 24.12, 24.12, 24.19, 24.25, 24.85, 24.23, 24.30]
- **`int_loop.js`** (`zqjs->qjs`, alternating): zqjs=[41.82, 42.27, 41.69, 41.82, 41.99, 41.94, 41.86, 41.89, 41.65, 41.91, 41.67] | qjs=[67.43, 67.85, 66.58, 69.01, 67.62, 69.67, 68.44, 64.67, 69.11, 69.04, 67.31]
- **`objects.js`** (`zqjs->qjs`, alternating): zqjs=[29.37, 29.51, 29.36, 29.62, 29.55, 29.30, 29.69, 29.74, 29.74, 29.46, 31.51] | qjs=[31.69, 31.95, 32.28, 30.85, 32.01, 31.89, 31.45, 32.09, 32.08, 31.65, 31.94]
- **`scopes.js`** (`zqjs->qjs`, alternating): zqjs=[24.11, 23.78, 23.74, 24.02, 23.84, 24.26, 23.72, 23.90, 23.93, 23.68, 23.71] | qjs=[34.50, 35.19, 35.12, 34.51, 34.73, 34.41, 34.98, 35.93, 34.50, 35.07, 37.56]
- **`strings.js`** (`zqjs->qjs`, alternating): zqjs=[8.53, 8.41, 8.59, 8.57, 8.51, 8.60, 8.62, 8.67, 8.79, 8.56, 8.36] | qjs=[11.53, 11.77, 11.46, 11.66, 11.51, 11.79, 11.48, 11.85, 11.31, 11.39, 11.33]
