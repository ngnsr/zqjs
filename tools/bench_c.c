/* C-ABI embedding benchmark harness (ReleaseFast).
 *
 * Measures ZQJS's C11 embedding boundary directly (reported separately from CLI-to-CLI
 * QuickJS comparisons):
 *   1. JS -> C native(a, b) throughput (1,000,000 calls, 11 runs)
 *   2. Host -> JS -> C native -> JS round-trip throughput (100,000 trips, 11 runs)
 *   3. 3,600-frame game-style loop (30 runs, per-frame p50/p95/max + per-run totals + GC telemetry)
 */

#define _POSIX_C_SOURCE 199309L

#include "zqjs.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CHECK(expr)                                                            \
    do {                                                                       \
        if (!(expr)) {                                                         \
            fprintf(stderr, "CHECK failed (%s:%d): %s\n", __FILE__, __LINE__, #expr); \
            abort();                                                           \
        }                                                                      \
    } while (0)

static uint64_t monotonic_ns(void *ctx) {
    (void)ctx;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static uint64_t thread_cpu_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static int cmp_u64(const void *a, const void *b) {
    uint64_t va = *(const uint64_t *)a;
    uint64_t vb = *(const uint64_t *)b;
    return (va > vb) - (va < vb);
}

static zqjs_status native_add2(
    zqjs_runtime *rt,
    void *ctx,
    const zqjs_handle *opt_this,
    const zqjs_handle *args,
    size_t argc,
    zqjs_native_out *out
) {
    (void)ctx;
    (void)opt_this;
    if (argc < 2) return ZQJS_ERR_INVALID_ARG;
    double a = 0.0, b = 0.0;
    if (zqjs_handle_number(rt, args[0], &a) != ZQJS_OK) return ZQJS_ERR_HOST;
    if (zqjs_handle_number(rt, args[1], &b) != ZQJS_OK) return ZQJS_ERR_HOST;
    zqjs_handle res = ZQJS_HANDLE_NULL;
    zqjs_status st = zqjs_new_number(rt, a + b, &res);
    if (st != ZQJS_OK) return st;
    out->has_result = true;
    out->result = res;
    return ZQJS_OK;
}

static zqjs_status native_roundtrip(
    zqjs_runtime *rt,
    void *ctx,
    const zqjs_handle *opt_this,
    const zqjs_handle *args,
    size_t argc,
    zqjs_native_out *out
) {
    (void)ctx;
    (void)opt_this;
    if (argc < 2) return ZQJS_ERR_INVALID_ARG;
    zqjs_failure fail;
    zqjs_handle res = ZQJS_HANDLE_NULL;
    zqjs_status st = zqjs_runtime_call(rt, args[0], NULL, &args[1], 1, &fail, &res);
    if (st != ZQJS_OK) return st;
    out->has_result = true;
    out->result = res;
    return ZQJS_OK;
}

static zqjs_status native_capture_fn(
    zqjs_runtime *rt,
    void *ctx,
    const zqjs_handle *opt_this,
    const zqjs_handle *args,
    size_t argc,
    zqjs_native_out *out
) {
    (void)opt_this;
    (void)out;
    if (argc < 1) return ZQJS_ERR_INVALID_ARG;
    zqjs_handle *slot = (zqjs_handle *)ctx;
    if (slot->owner != NULL) {
        CHECK(zqjs_handle_release(rt, *slot) == ZQJS_OK);
    }
    return zqjs_handle_dup(rt, args[0], slot);
}

static zqjs_status native_noop_draw(
    zqjs_runtime *rt,
    void *ctx,
    const zqjs_handle *opt_this,
    const zqjs_handle *args,
    size_t argc,
    zqjs_native_out *out
) {
    (void)rt;
    (void)opt_this;
    (void)args;
    (void)argc;
    (void)out;
    uint64_t *count = (uint64_t *)ctx;
    (*count)++;
    return ZQJS_OK;
}

static void bench_js_to_c_native(void) {
    enum { WARMUPS = 2, RUNS = 11, CALLS = 1000000 };
    uint64_t samples[RUNS];

    zqjs_options opts = zqjs_options_default();
    opts.limits.max_handles = 64;
    opts.limits.max_steps = 50000000ull;

    const char *src =
        "let acc = 0;"
        "for (let i = 0; i < 1000000; i++) {"
        "  acc = add2(acc, i % 8);"
        "}";

    for (int r = 0; r < WARMUPS + RUNS; r++) {
        zqjs_runtime *rt = NULL;
        CHECK(zqjs_runtime_create(&opts, &rt) == ZQJS_OK);
        CHECK(zqjs_runtime_define_global_function(rt, "add2", 4, native_add2, NULL) == ZQJS_OK);

        /* Warm 1 handle slot so initial table capacity is established before measurement */
        zqjs_handle warm = ZQJS_HANDLE_NULL;
        CHECK(zqjs_new_number(rt, 1.0, &warm) == ZQJS_OK);
        CHECK(zqjs_handle_release(rt, warm) == ZQJS_OK);

        zqjs_memory before_mem;
        CHECK(zqjs_runtime_memory(rt, &before_mem) == ZQJS_OK);

        zqjs_diagnostic diag;
        zqjs_program *prog = NULL;
        CHECK(zqjs_runtime_compile(rt, "native_1m.js", 12, src, strlen(src), &diag, &prog) == ZQJS_OK);

        zqjs_failure fail;
        uint64_t t0 = monotonic_ns(NULL);
        CHECK(zqjs_runtime_run(rt, prog, &fail) == ZQJS_OK);
        uint64_t dt = monotonic_ns(NULL) - t0;

        zqjs_memory after_mem;
        CHECK(zqjs_runtime_memory(rt, &after_mem) == ZQJS_OK);
        CHECK(after_mem.handle_bytes == before_mem.handle_bytes);

        CHECK(zqjs_program_destroy(prog) == ZQJS_OK);
        CHECK(zqjs_runtime_destroy(rt) == ZQJS_OK);
        if (r >= WARMUPS) samples[r - WARMUPS] = dt;
    }

    qsort(samples, RUNS, sizeof(uint64_t), cmp_u64);
    uint64_t med = samples[RUNS / 2];
    double ns_per_call = (double)med / (double)CALLS;
    double calls_per_sec = 1e9 / ns_per_call;
    printf("js_to_c_native\truns=%d\tcalls=%d\tmed_ms=%.3f\tmin_ms=%.3f\tmax_ms=%.3f\tns_per_call=%.1f\tcalls_per_sec=%.0f\n",
        RUNS, CALLS,
        (double)med / 1e6,
        (double)samples[0] / 1e6,
        (double)samples[RUNS - 1] / 1e6,
        ns_per_call,
        calls_per_sec);
}

static void bench_roundtrip(void) {
    enum { WARMUPS = 2, RUNS = 11, TRIPS = 100000 };
    uint64_t samples[RUNS];

    zqjs_options opts = zqjs_options_default();
    opts.limits.max_handles = 64;
    opts.limits.max_steps = 50000000ull;

    const char *src =
        "function inner(x) { return x + 1; }"
        "setEntry(function(n) { return roundTrip(inner, n); });";

    for (int r = 0; r < WARMUPS + RUNS; r++) {
        zqjs_runtime *rt = NULL;
        CHECK(zqjs_runtime_create(&opts, &rt) == ZQJS_OK);
        zqjs_handle entry = ZQJS_HANDLE_NULL;
        CHECK(zqjs_runtime_define_global_function(rt, "setEntry", 8, native_capture_fn, &entry) == ZQJS_OK);
        CHECK(zqjs_runtime_define_global_function(rt, "roundTrip", 9, native_roundtrip, NULL) == ZQJS_OK);

        zqjs_diagnostic diag;
        zqjs_program *prog = NULL;
        CHECK(zqjs_runtime_compile(rt, "rt.js", 5, src, strlen(src), &diag, &prog) == ZQJS_OK);
        zqjs_failure fail;
        CHECK(zqjs_runtime_run(rt, prog, &fail) == ZQJS_OK);

        zqjs_memory before_mem;
        CHECK(zqjs_runtime_memory(rt, &before_mem) == ZQJS_OK);

        uint64_t t0 = monotonic_ns(NULL);
        for (int i = 0; i < TRIPS; i++) {
            zqjs_handle arg = ZQJS_HANDLE_NULL;
            zqjs_handle res = ZQJS_HANDLE_NULL;
            CHECK(zqjs_new_number(rt, (double)(i & 255), &arg) == ZQJS_OK);
            CHECK(zqjs_runtime_call(rt, entry, NULL, &arg, 1, &fail, &res) == ZQJS_OK);
            CHECK(zqjs_handle_release(rt, res) == ZQJS_OK);
            CHECK(zqjs_handle_release(rt, arg) == ZQJS_OK);
        }
        uint64_t dt = monotonic_ns(NULL) - t0;

        zqjs_memory after_mem;
        CHECK(zqjs_runtime_memory(rt, &after_mem) == ZQJS_OK);
        CHECK(after_mem.handle_bytes == before_mem.handle_bytes);

        CHECK(zqjs_handle_release(rt, entry) == ZQJS_OK);
        CHECK(zqjs_program_destroy(prog) == ZQJS_OK);
        CHECK(zqjs_runtime_destroy(rt) == ZQJS_OK);
        if (r >= WARMUPS) samples[r - WARMUPS] = dt;
    }

    qsort(samples, RUNS, sizeof(uint64_t), cmp_u64);
    uint64_t med = samples[RUNS / 2];
    double ns_per_trip = (double)med / (double)TRIPS;
    double trips_per_sec = 1e9 / ns_per_trip;
    printf("host_js_c_js_roundtrip\truns=%d\ttrips=%d\tmed_ms=%.3f\tmin_ms=%.3f\tmax_ms=%.3f\tns_per_call=%.1f\tcalls_per_sec=%.0f\n",
        RUNS, TRIPS,
        (double)med / 1e6,
        (double)samples[0] / 1e6,
        (double)samples[RUNS - 1] / 1e6,
        ns_per_trip,
        trips_per_sec);
}

static void bench_frame_loop(void) {
    enum { WARMUPS = 2, RUNS = 30, FRAMES = 3600 };
    uint64_t run_totals[RUNS];
    uint64_t *all_frames = (uint64_t *)malloc((size_t)RUNS * (size_t)FRAMES * sizeof(uint64_t));
    CHECK(all_frames != NULL);

    const char *src =
        "let entities = [];"
        "for (let i = 0; i < 16; i++) entities.push({ x: i * 10, y: i * 5, vx: 1.5, vy: -1.0 });"
        "let particles = [];"
        "setUpdate(function(dt) {"
        "  for (let i = 0; i < entities.length; i++) {"
        "    let e = entities[i];"
        "    e.x += e.vx * dt; e.y += e.vy * dt;"
        "  }"
        "  for (let k = 0; k < 4; k++) particles.push({ x: k, y: dt, life: 0.25 });"
        "  let w = 0;"
        "  for (let i = 0; i < particles.length; i++) {"
        "    let p = particles[i];"
        "    p.life -= dt;"
        "    if (p.life > 0) { particles[w] = p; w++; }"
        "  }"
        "  particles.length = w;"
        "});"
        "setDraw(function() {"
        "  for (let i = 0; i < entities.length; i++) drawOp(entities[i].x, entities[i].y);"
        "  for (let i = 0; i < particles.length; i++) drawOp(particles[i].x, particles[i].y);"
        "});";

    zqjs_memory last_mem = { 0 };
    uint64_t outlier_wall_ns = 0;
    uint64_t outlier_cpu_ns = 0;
    int outlier_run = -1;
    int outlier_frame = -1;

    for (int r = 0; r < WARMUPS + RUNS; r++) {
        zqjs_options opts = zqjs_options_default();
        opts.limits.max_heap_bytes = 8u * 1024u * 1024u;
        opts.limits.nursery_bytes = 128u * 1024u;
        opts.limits.max_handles = 64;
        opts.limits.max_steps = 100000ull;
        opts.clock_fn = monotonic_ns;

        zqjs_runtime *rt = NULL;
        CHECK(zqjs_runtime_create(&opts, &rt) == ZQJS_OK);

        zqjs_handle on_update = ZQJS_HANDLE_NULL;
        zqjs_handle on_draw = ZQJS_HANDLE_NULL;
        uint64_t draw_ops = 0;
        CHECK(zqjs_runtime_define_global_function(rt, "setUpdate", 9, native_capture_fn, &on_update) == ZQJS_OK);
        CHECK(zqjs_runtime_define_global_function(rt, "setDraw", 7, native_capture_fn, &on_draw) == ZQJS_OK);
        CHECK(zqjs_runtime_define_global_function(rt, "drawOp", 6, native_noop_draw, &draw_ops) == ZQJS_OK);

        zqjs_diagnostic diag;
        zqjs_program *prog = NULL;
        CHECK(zqjs_runtime_compile(rt, "frame.js", 8, src, strlen(src), &diag, &prog) == ZQJS_OK);
        zqjs_failure fail;
        CHECK(zqjs_runtime_run(rt, prog, &fail) == ZQJS_OK);

        zqjs_memory before_mem;
        CHECK(zqjs_runtime_memory(rt, &before_mem) == ZQJS_OK);

        uint64_t run_start = monotonic_ns(NULL);
        for (int f = 0; f < FRAMES; f++) {
            uint64_t f_start = monotonic_ns(NULL);
            uint64_t c_start = thread_cpu_ns();
            zqjs_handle dt_h = ZQJS_HANDLE_NULL;
            zqjs_handle u_res = ZQJS_HANDLE_NULL;
            zqjs_handle d_res = ZQJS_HANDLE_NULL;

            CHECK(zqjs_new_number(rt, 1.0 / 60.0, &dt_h) == ZQJS_OK);
            CHECK(zqjs_runtime_call(rt, on_update, NULL, &dt_h, 1, &fail, &u_res) == ZQJS_OK);
            CHECK(zqjs_handle_release(rt, u_res) == ZQJS_OK);
            CHECK(zqjs_handle_release(rt, dt_h) == ZQJS_OK);

            CHECK(zqjs_runtime_call(rt, on_draw, NULL, NULL, 0, &fail, &d_res) == ZQJS_OK);
            CHECK(zqjs_handle_release(rt, d_res) == ZQJS_OK);

            uint64_t f_cpu = thread_cpu_ns() - c_start;
            uint64_t f_dt = monotonic_ns(NULL) - f_start;
            if (r >= WARMUPS) {
                all_frames[(size_t)(r - WARMUPS) * (size_t)FRAMES + (size_t)f] = f_dt;
                if (f_dt > outlier_wall_ns) {
                    outlier_wall_ns = f_dt;
                    outlier_cpu_ns = f_cpu;
                    outlier_run = r - WARMUPS;
                    outlier_frame = f;
                }
            }
        }
        uint64_t run_dt = monotonic_ns(NULL) - run_start;

        CHECK(zqjs_runtime_memory(rt, &last_mem) == ZQJS_OK);
        CHECK(last_mem.handle_bytes == before_mem.handle_bytes);

        CHECK(zqjs_handle_release(rt, on_update) == ZQJS_OK);
        CHECK(zqjs_handle_release(rt, on_draw) == ZQJS_OK);
        CHECK(zqjs_program_destroy(prog) == ZQJS_OK);
        CHECK(zqjs_runtime_destroy(rt) == ZQJS_OK);

        if (r >= WARMUPS) {
            run_totals[r - WARMUPS] = run_dt;
        }
    }

    qsort(run_totals, RUNS, sizeof(uint64_t), cmp_u64);
    size_t total_frames = (size_t)RUNS * (size_t)FRAMES;
    qsort(all_frames, total_frames, sizeof(uint64_t), cmp_u64);

    uint64_t run_med = run_totals[RUNS / 2];
    uint64_t run_p95 = run_totals[(size_t)(0.95 * (RUNS - 1))];
    uint64_t f_med = all_frames[total_frames / 2];
    uint64_t f_p95 = all_frames[(size_t)(0.95 * (total_frames - 1))];
    uint64_t f_max = all_frames[total_frames - 1];

    printf("frame_loop_3600\truns=%d\tframes_per_run=%d\trun_med_ms=%.3f\trun_p95_ms=%.3f\trun_min_ms=%.3f\trun_max_ms=%.3f\tframe_p50_us=%.2f\tframe_p95_us=%.2f\tframe_max_us=%.2f\toutlier_run=%d\toutlier_frame=%d\toutlier_cpu_us=%.2f\theap_bytes=%zu\thandle_bytes=%zu\tgc_minor=%llu\tgc_major=%llu\tmax_gc_pause_us=%.2f\n",
        RUNS, FRAMES,
        (double)run_med / 1e6,
        (double)run_p95 / 1e6,
        (double)run_totals[0] / 1e6,
        (double)run_totals[RUNS - 1] / 1e6,
        (double)f_med / 1e3,
        (double)f_p95 / 1e3,
        (double)f_max / 1e3,
        outlier_run,
        outlier_frame,
        (double)outlier_cpu_ns / 1e3,
        last_mem.heap_bytes,
        last_mem.handle_bytes,
        (unsigned long long)last_mem.minor_collections,
        (unsigned long long)last_mem.major_collections,
        (double)last_mem.max_gc_pause_ns / 1e3);

    free(all_frames);
}

int main(void) {
    bench_js_to_c_native();
    bench_roundtrip();
    bench_frame_loop();
    return 0;
}
