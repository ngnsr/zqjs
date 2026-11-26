# ZQJS Performance Baseline

## Environment & Pinning
- **Date (UTC):** 2026-11-26T14:13:52Z
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
| `arrays.js` | 151.68 | [150.25, 152.57] | 165.31 | [163.91, 167.78] | **0.92x** | 3808 | 1936 |
| `branch_dense.js` | 59.96 | [59.01, 60.43] | 104.22 | [103.25, 105.31] | **0.58x** | 2816 | 1904 |
| `call_chain.js` | 45.79 | [44.41, 48.10] | 50.53 | [49.56, 51.63] | **0.91x** | 3040 | 1920 |
| `closures.js` | 46.00 | [43.54, 46.56] | 121.98 | [119.92, 123.91] | **0.38x** | 3328 | 1904 |
| `fib.js` | 26.34 | [26.02, 26.55] | 32.82 | [32.54, 33.54] | **0.80x** | 2960 | 1904 |
| `float_math.js` | 94.78 | [94.30, 95.18] | 133.76 | [130.42, 134.81] | **0.71x** | 2832 | 1904 |
| `global_reads.js` | 22.59 | [22.05, 22.84] | 24.10 | [23.43, 25.48] | **0.94x** | 2832 | 1904 |
| `int_loop.js` | 42.12 | [41.68, 42.28] | 67.89 | [64.75, 69.53] | **0.62x** | 2800 | 1904 |
| `objects.js` | 31.96 | [31.44, 32.71] | 31.76 | [31.36, 32.77] | **1.01x** | 3744 | 1920 |
| `scopes.js` | 24.14 | [23.88, 24.31] | 34.91 | [33.44, 35.77] | **0.69x** | 2816 | 1920 |
| `strings.js` | 8.62 | [8.39, 8.93] | 11.46 | [11.22, 11.70] | **0.75x** | 3024 | 1904 |

## 3. ZQJS Split-Phase & GC Benchmarks (`zig build bench-js -- --gc`)
```text
# bench-js: zig 0.17.1, aarch64-macos (apple_m4), fast, warmups=2, measured=11, smp_allocator
program	steps	allocated	peak	end	gc(m/M)	compile_med_ms	compile_min_ms	compile_max_ms	exec_med_ms	exec_min_ms	exec_max_ms	total_med_ms	total_min_ms	total_max_ms
bench/suite/js/arrays.js	55800013	91288734	457186	412874	210/0	0.018	0.012	0.031	147.234	146.582	147.695	147.267	146.618	147.739
bench/suite/js/branch_dense.js	23801249	862	862	862	0/0	0.014	0.013	0.022	57.571	57.446	57.758	57.587	57.464	57.773
bench/suite/js/call_chain.js	21000018	1736	1624	1624	0/0	0.009	0.008	0.018	41.180	41.039	41.803	41.191	41.050	41.813
bench/suite/js/closures.js	18000015	92001568	327872	297328	350/0	0.011	0.009	0.026	42.082	41.798	43.547	42.107	41.821	43.586
bench/suite/js/fib.js	9984482	806	806	806	0/0	0.006	0.004	0.011	24.018	23.651	25.229	24.025	23.657	25.238
bench/suite/js/float_math.js	46000020	1298	1186	1186	0/0	0.012	0.010	0.022	92.332	91.550	92.460	92.348	91.561	92.472
bench/suite/js/global_reads.js	11000022	874	874	874	0/0	0.007	0.006	0.013	19.717	19.477	19.853	19.724	19.487	19.862
bench/suite/js/int_loop.js	22000011	618	618	618	0/0	0.006	0.006	0.017	39.744	39.617	40.140	39.752	39.625	40.148
bench/suite/js/objects.js	7600020	38490122	370966	298006	146/0	0.012	0.012	0.021	28.878	28.530	29.031	28.900	28.561	29.059
bench/suite/js/scopes.js	12000013	622	622	622	0/0	0.006	0.006	0.006	21.989	21.757	22.018	21.996	21.764	22.025
bench/suite/js/strings.js	1400013	42714350	286696	253906	162/0	0.005	0.005	0.006	6.398	6.296	6.477	6.409	6.307	6.488
bench/gc/game_100k.js	27002127	388648248	34081410	33983802	1466/3	0.029	0.025	0.039	112.555	111.720	113.239	113.803	112.905	114.411
bench/gc/game_1m.js	26400727	484430516	336702176	336570658	1689/5	0.032	0.030	0.038	172.293	169.997	177.381	183.552	181.198	189.602
bench/gc/game_big_container.js	23402227	350671942	202943602	202921080	1178/4	0.033	0.032	0.037	117.005	116.647	119.944	124.930	124.366	127.944
bench/gc/game_big_dictionary.js	28606327	564484480	81313828	81104348	2006/4	0.039	0.036	0.049	200.661	196.729	206.667	205.179	201.141	211.219
bench/gc/game_growing.js	31503324	463432500	101092604	101035514	1718/5	0.038	0.032	0.047	147.666	146.080	148.943	151.432	149.788	152.958
```

## 4. ZQJS C-ABI Embedding Benchmarks (`zig build bench-c`, separate from QuickJS)
```text
js_to_c_native	runs=11	calls=1000000	med_ms=135.714	min_ms=127.724	max_ms=145.834	ns_per_call=135.7	calls_per_sec=7368437
host_js_c_js_roundtrip	runs=11	trips=100000	med_ms=24.159	min_ms=23.654	max_ms=25.146	ns_per_call=241.6	calls_per_sec=4139244
frame_loop_3600	runs=30	frames_per_run=3600	run_med_ms=62.097	run_p95_ms=62.784	run_min_ms=61.780	run_max_ms=63.202	frame_p50_us=17.00	frame_p95_us=18.00	frame_max_us=53.00	outlier_run=9	outlier_frame=2620	outlier_cpu_us=52.50	heap_bytes=253914	handle_bytes=384	gc_minor=20	gc_major=1	max_gc_pause_us=21.00
```

## 5. Individual CLI Sample Timings (ms, alternating order)
- **`arrays.js`** (`zqjs->qjs`, alternating): zqjs=[150.27, 150.25, 150.61, 152.57, 150.26, 151.97, 152.07, 152.06, 151.76, 151.68, 151.29] | qjs=[165.31, 164.49, 164.46, 167.78, 164.70, 166.26, 163.91, 166.99, 164.42, 166.79, 165.86]
- **`branch_dense.js`** (`zqjs->qjs`, alternating): zqjs=[60.27, 60.19, 60.07, 59.96, 59.79, 60.26, 59.01, 60.43, 59.91, 59.85, 59.84] | qjs=[105.11, 104.22, 104.02, 104.38, 105.31, 103.52, 104.29, 104.78, 104.14, 103.77, 103.25]
- **`call_chain.js`** (`zqjs->qjs`, alternating): zqjs=[44.41, 46.03, 45.03, 44.69, 46.53, 45.63, 48.10, 45.79, 45.03, 46.55, 47.26] | qjs=[50.18, 50.21, 50.50, 50.04, 50.79, 50.91, 50.66, 51.60, 50.53, 51.63, 49.56]
- **`closures.js`** (`zqjs->qjs`, alternating): zqjs=[43.54, 46.56, 46.00, 46.13, 45.77, 46.18, 45.89, 45.28, 45.69, 46.12, 46.51] | qjs=[120.72, 122.16, 120.96, 121.98, 122.94, 121.53, 122.50, 121.95, 123.04, 119.92, 123.91]
- **`fib.js`** (`zqjs->qjs`, alternating): zqjs=[26.17, 26.45, 26.34, 26.08, 26.41, 26.37, 26.10, 26.02, 26.07, 26.55, 26.41] | qjs=[33.12, 33.13, 32.76, 32.84, 33.42, 32.72, 33.54, 32.71, 32.57, 32.82, 32.54]
- **`float_math.js`** (`zqjs->qjs`, alternating): zqjs=[95.11, 94.87, 94.56, 94.77, 95.18, 94.43, 94.78, 94.74, 95.10, 95.02, 94.30] | qjs=[134.81, 134.42, 130.42, 134.28, 134.34, 133.26, 133.76, 133.64, 134.21, 132.75, 132.88]
- **`global_reads.js`** (`zqjs->qjs`, alternating): zqjs=[22.84, 22.82, 22.65, 22.56, 22.51, 22.33, 22.05, 22.53, 22.83, 22.66, 22.59] | qjs=[24.32, 25.48, 24.48, 23.43, 24.09, 24.10, 24.05, 24.25, 24.94, 23.73, 24.07]
- **`int_loop.js`** (`zqjs->qjs`, alternating): zqjs=[42.23, 42.20, 42.28, 42.20, 42.07, 41.98, 41.68, 42.22, 42.00, 42.12, 41.97] | qjs=[68.03, 67.89, 69.53, 68.64, 67.32, 67.58, 68.73, 64.75, 67.48, 67.02, 68.78]
- **`objects.js`** (`zqjs->qjs`, alternating): zqjs=[31.85, 31.98, 31.95, 31.77, 32.06, 32.54, 31.91, 31.96, 31.44, 32.71, 32.22] | qjs=[31.80, 31.95, 32.77, 31.80, 31.36, 32.47, 31.76, 31.66, 31.63, 31.47, 31.72]
- **`scopes.js`** (`zqjs->qjs`, alternating): zqjs=[24.23, 24.31, 24.16, 24.14, 24.11, 24.07, 24.02, 24.31, 24.14, 24.10, 23.88] | qjs=[33.44, 35.23, 35.53, 34.32, 34.56, 35.77, 35.15, 35.14, 34.63, 34.91, 34.32]
- **`strings.js`** (`zqjs->qjs`, alternating): zqjs=[8.62, 8.39, 8.44, 8.55, 8.76, 8.84, 8.63, 8.93, 8.78, 8.54, 8.54] | qjs=[11.62, 11.34, 11.25, 11.47, 11.25, 11.47, 11.70, 11.39, 11.56, 11.22, 11.46]
