# ZQJS Performance Baseline

## Environment & Pinning
- **Date (UTC):** 2026-11-24T21:55:19Z
- **Host:** Darwin arm64 (macOS-15.8.3-arm64-arm-64bit-Mach-O)
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
| `arrays.js` | 143.55 | [142.62, 188.89] | 165.85 | [163.53, 167.95] | **0.87x** | 3936 | 1936 |
| `branch_dense.js` | 61.63 | [60.73, 62.23] | 104.25 | [101.87, 105.91] | **0.59x** | 2864 | 1904 |
| `call_chain.js` | 49.38 | [47.19, 50.44] | 51.64 | [50.67, 53.48] | **0.96x** | 3040 | 1920 |
| `closures.js` | 49.33 | [47.54, 59.45] | 126.75 | [122.84, 128.96] | **0.39x** | 3472 | 2032 |
| `fib.js` | 25.70 | [25.53, 26.56] | 33.27 | [32.37, 34.10] | **0.77x** | 3008 | 1904 |
| `float_math.js` | 94.76 | [93.78, 97.94] | 134.87 | [130.60, 137.82] | **0.70x** | 2880 | 1904 |
| `global_reads.js` | 21.78 | [21.17, 22.75] | 25.16 | [23.89, 25.78] | **0.87x** | 2864 | 1904 |
| `int_loop.js` | 42.34 | [41.74, 43.40] | 67.80 | [66.91, 69.94] | **0.62x** | 2864 | 1904 |
| `objects.js` | 31.55 | [30.91, 32.51] | 32.48 | [31.59, 32.89] | **0.97x** | 3840 | 1920 |
| `scopes.js` | 23.51 | [23.41, 23.66] | 34.63 | [33.08, 36.25] | **0.68x** | 2864 | 1920 |
| `strings.js` | 11.93 | [11.59, 12.06] | 11.54 | [11.15, 11.95] | **1.03x** | 3232 | 1904 |

## 3. ZQJS Split-Phase & GC Benchmarks (`zig build bench-js -- --gc`)
```text
# bench-js: zig 0.17.1, aarch64-macos (apple_m4), fast, warmups=2, measured=11, smp_allocator
program	steps	allocated	peak	end	gc(m/M)	compile_med_ms	compile_min_ms	compile_max_ms	exec_med_ms	exec_min_ms	exec_max_ms	total_med_ms	total_min_ms	total_max_ms
bench/suite/js/arrays.js	55800013	91265900	435216	368824	210/0	0.030	0.014	0.034	140.112	138.894	175.287	140.161	138.923	175.337
bench/suite/js/branch_dense.js	23801249	670	670	670	0/0	0.014	0.013	0.018	58.618	58.513	58.851	58.632	58.528	58.867
bench/suite/js/call_chain.js	21000018	1448	1336	1336	0/0	0.009	0.008	0.009	39.898	39.755	40.100	39.907	39.765	40.110
bench/suite/js/closures.js	18000015	92001280	327584	296672	350/0	0.011	0.009	0.024	42.430	42.023	42.665	42.457	42.054	42.707
bench/suite/js/fib.js	9984482	678	678	678	0/0	0.005	0.005	0.018	23.208	23.152	23.266	23.220	23.158	23.276
bench/suite/js/float_math.js	46000020	1042	944	930	0/0	0.010	0.010	0.011	91.264	90.833	92.306	91.275	90.844	92.320
bench/suite/js/global_reads.js	11000022	682	682	682	0/0	0.006	0.006	0.018	19.220	18.817	19.386	19.227	18.827	19.393
bench/suite/js/int_loop.js	22000011	490	490	490	0/0	0.018	0.005	0.025	39.864	39.517	94.887	39.888	39.524	94.894
bench/suite/js/objects.js	7600020	38467164	348872	253832	146/0	0.025	0.015	0.031	29.022	28.771	29.504	29.060	28.801	29.548
bench/suite/js/scopes.js	12000013	494	494	494	0/0	0.008	0.007	0.012	21.482	21.206	21.637	21.492	21.215	21.647
bench/suite/js/strings.js	1400013	33114126	277440	62558	126/0	0.006	0.005	0.013	8.963	8.653	9.172	8.974	8.670	9.184
bench/gc/game_100k.js	27002127	327825126	30750490	30624820	1235/3	0.045	0.032	0.049	128.372	126.448	152.576	130.060	127.991	154.261
bench/gc/game_1m.js	26400727	433207394	304643528	304542888	1493/5	0.036	0.032	0.045	205.128	185.903	217.870	221.021	204.140	234.689
bench/gc/game_big_container.js	23402227	331448820	202884952	202863202	1105/4	0.044	0.034	0.060	120.610	118.005	155.676	149.449	130.945	194.566
bench/gc/game_big_dictionary.js	28606327	474851662	74989502	74900104	1662/4	0.045	0.038	0.050	275.619	229.274	314.599	284.403	236.911	322.603
bench/gc/game_growing.js	31503324	396209378	91664832	91430526	1462/5	0.044	0.032	0.053	168.202	165.303	171.268	181.048	179.129	184.318
```

## 4. ZQJS C-ABI Embedding Benchmarks (`zig build bench-c`, separate from QuickJS)
```text
js_to_c_native	runs=11	calls=1000000	med_ms=131.602	min_ms=110.085	max_ms=184.930	ns_per_call=131.6	calls_per_sec=7598669
host_js_c_js_roundtrip	runs=11	trips=100000	med_ms=25.157	min_ms=24.540	max_ms=26.960	ns_per_call=251.6	calls_per_sec=3975037
frame_loop_3600	runs=30	frames_per_run=3600	run_med_ms=42.123	run_p95_ms=47.517	run_min_ms=41.419	run_max_ms=48.555	frame_p50_us=12.00	frame_p95_us=12.00	frame_max_us=579.00	outlier_run=19	outlier_frame=3308	outlier_cpu_us=46.50	heap_bytes=185222	handle_bytes=384	gc_minor=20	gc_major=1	max_gc_pause_us=28.00
```

## 5. Individual CLI Sample Timings (ms, alternating order)
- **`arrays.js`** (`zqjs->qjs`, alternating): zqjs=[143.23, 188.89, 144.77, 143.44, 143.73, 143.55, 143.60, 143.24, 143.57, 142.95, 142.62] | qjs=[167.01, 165.93, 165.63, 163.53, 167.95, 166.11, 166.02, 164.43, 165.12, 165.85, 163.98]
- **`branch_dense.js`** (`zqjs->qjs`, alternating): zqjs=[61.66, 60.73, 61.16, 61.65, 61.48, 62.23, 61.81, 61.80, 61.45, 61.31, 61.63] | qjs=[104.95, 104.37, 104.25, 104.40, 103.88, 103.09, 105.91, 101.87, 104.60, 104.14, 103.64]
- **`call_chain.js`** (`zqjs->qjs`, alternating): zqjs=[47.19, 47.71, 47.73, 47.66, 47.60, 50.44, 49.57, 49.78, 50.08, 49.38, 49.93] | qjs=[51.52, 50.67, 51.74, 51.43, 52.30, 51.72, 52.85, 51.64, 51.55, 53.48, 51.33]
- **`closures.js`** (`zqjs->qjs`, alternating): zqjs=[49.02, 49.81, 50.31, 50.73, 49.33, 48.55, 48.41, 47.54, 48.11, 59.45, 59.28] | qjs=[127.86, 127.91, 128.78, 128.96, 126.75, 127.49, 124.12, 124.11, 124.63, 122.84, 125.38]
- **`fib.js`** (`zqjs->qjs`, alternating): zqjs=[25.65, 25.70, 25.66, 26.56, 26.46, 25.68, 25.75, 25.60, 25.53, 26.15, 26.00] | qjs=[32.93, 32.69, 33.48, 34.10, 33.81, 33.27, 33.68, 33.05, 32.37, 33.44, 33.26]
- **`float_math.js`** (`zqjs->qjs`, alternating): zqjs=[94.93, 96.48, 96.52, 94.76, 93.99, 93.91, 93.78, 97.94, 95.46, 94.52, 94.32] | qjs=[133.80, 137.23, 132.58, 134.87, 133.38, 130.60, 137.82, 135.61, 134.94, 137.51, 133.64]
- **`global_reads.js`** (`zqjs->qjs`, alternating): zqjs=[21.30, 21.93, 22.75, 22.42, 22.34, 21.91, 21.78, 21.45, 21.68, 21.58, 21.17] | qjs=[24.36, 25.78, 25.52, 25.68, 25.16, 25.45, 24.97, 23.89, 25.19, 24.42, 24.65]
- **`int_loop.js`** (`zqjs->qjs`, alternating): zqjs=[43.06, 43.28, 43.40, 42.97, 42.60, 42.34, 41.92, 41.92, 41.74, 42.26, 41.81] | qjs=[67.14, 68.47, 67.80, 68.73, 69.50, 66.91, 69.31, 67.15, 67.15, 67.19, 69.94]
- **`objects.js`** (`zqjs->qjs`, alternating): zqjs=[31.55, 30.91, 30.91, 31.20, 31.16, 32.51, 31.86, 31.97, 31.34, 32.33, 32.31] | qjs=[31.66, 31.96, 31.59, 32.05, 32.62, 32.82, 32.80, 32.89, 32.78, 32.48, 31.71]
- **`scopes.js`** (`zqjs->qjs`, alternating): zqjs=[23.64, 23.66, 23.51, 23.61, 23.49, 23.59, 23.50, 23.62, 23.45, 23.50, 23.41] | qjs=[34.53, 36.25, 35.49, 34.49, 35.67, 33.08, 34.82, 34.63, 34.40, 35.96, 34.38]
- **`strings.js`** (`zqjs->qjs`, alternating): zqjs=[11.84, 11.80, 11.94, 12.06, 11.90, 12.06, 11.86, 11.98, 11.59, 11.98, 11.93] | qjs=[11.15, 11.57, 11.49, 11.34, 11.44, 11.54, 11.53, 11.59, 11.95, 11.57, 11.69]
