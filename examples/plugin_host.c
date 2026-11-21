/*
 * M13.2: Multi-plugin cooperative C11 host (zero external dependencies).
 *
 * Exercises:
 * - Multiple cooperative `zqjs_execution`s interleaved in one `zqjs_runtime`
 * - Structured C <-> JS object/array creation & inspection via `zqjs.h`
 * - `try/catch`, `Math`, `Array`, and `String` language floor
 * - Execution-level fault containment (uncaught JS throw & per-execution `max_steps`)
 * - Isolated-runtime `max_heap_bytes` recovery after execution teardown + GC
 * - Repeated execution/teardown memory & handle-byte stability
 */

#include "zqjs.h"

#include <assert.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define MAX_PLUGINS 4
#define SLICE_STEPS 48ull
#define MAX_ROUNDS 256

typedef enum plugin_state {
    PLUGIN_SUSPENDED = 0,
    PLUGIN_FINISHED = 1,
    PLUGIN_FAULTED = 2
} plugin_state;

typedef struct plugin_record {
    const char *name;
    bool submitted;
    double num_out;
    char text_out[128];
} plugin_record;

typedef struct host_ctx {
    plugin_record records[MAX_PLUGINS];
    size_t count;
} host_ctx;

static bool on_print(void *ctx, const char *bytes, size_t len) {
    (void)ctx;
    return fwrite(bytes, 1, len, stdout) == len;
}

static zqjs_status make_ascii_string(zqjs_runtime *rt, const char *s, zqjs_handle *out) {
    uint16_t buf[128];
    size_t n = strlen(s);
    assert(n <= sizeof(buf) / sizeof(buf[0]));
    for (size_t i = 0; i < n; i++) buf[i] = (uint16_t)(unsigned char)s[i];
    return zqjs_new_string_utf16(rt, buf, n, out);
}

static void read_ascii_string(zqjs_runtime *rt, zqjs_handle h, char *dst, size_t cap) {
    uint16_t ubuf[127];
    size_t full_len = 0;
    assert(zqjs_handle_string_utf16(rt, h, ubuf, sizeof(ubuf) / sizeof(ubuf[0]), &full_len) == ZQJS_OK);
    size_t n = full_len < cap - 1 ? full_len : cap - 1;
    for (size_t i = 0; i < n; i++) dst[i] = ubuf[i] < 128u ? (char)ubuf[i] : '?';
    dst[n] = '\0';
}

static plugin_record *find_record(host_ctx *ctx, const char *name) {
    for (size_t i = 0; i < ctx->count; i++) {
        if (strcmp(ctx->records[i].name, name) == 0) return &ctx->records[i];
    }
    return NULL;
}

static zqjs_status throw_type(zqjs_runtime *rt, const char *msg) {
    uint16_t ubuf[64];
    size_t n = strlen(msg);
    if (n > sizeof(ubuf) / sizeof(ubuf[0])) n = sizeof(ubuf) / sizeof(ubuf[0]);
    for (size_t i = 0; i < n; i++) ubuf[i] = (uint16_t)(unsigned char)msg[i];
    zqjs_runtime_throw_js(rt, ZQJS_ERROR_TYPE, ubuf, n);
    return ZQJS_ERR_THROWN;
}

/* fetchTask(pluginName) -> { id: 101, name: pluginName, values: [9, 16, 25], tags: ["alpha", "Beta", "gamma"] } */
static zqjs_status native_fetch_task(
    zqjs_runtime *rt,
    void *raw_ctx,
    const zqjs_handle *opt_this,
    const zqjs_handle *args,
    size_t argc,
    zqjs_native_out *out
) {
    (void)opt_this;
    (void)raw_ctx;
    if (argc < 1) return throw_type(rt, "fetchTask expects plugin name");

    char pname[64];
    read_ascii_string(rt, args[0], pname, sizeof(pname));

    zqjs_handle task = ZQJS_HANDLE_NULL;
    zqjs_handle id_h = ZQJS_HANDLE_NULL;
    zqjs_handle name_h = ZQJS_HANDLE_NULL;
    zqjs_handle vals = ZQJS_HANDLE_NULL;
    zqjs_handle tags = ZQJS_HANDLE_NULL;
    zqjs_failure fail;

    assert(zqjs_new_object(rt, &task) == ZQJS_OK);
    assert(zqjs_new_number(rt, 101.0, &id_h) == ZQJS_OK);
    assert(make_ascii_string(rt, pname, &name_h) == ZQJS_OK);
    assert(zqjs_new_array(rt, &vals) == ZQJS_OK);
    assert(zqjs_new_array(rt, &tags) == ZQJS_OK);

    const double nums[3] = { 9.0, 16.0, 25.0 };
    for (uint32_t i = 0; i < 3; i++) {
        zqjs_handle elem = ZQJS_HANDLE_NULL;
        assert(zqjs_new_number(rt, nums[i], &elem) == ZQJS_OK);
        assert(zqjs_handle_set_index(rt, vals, i, elem, &fail) == ZQJS_OK);
        assert(zqjs_handle_release(rt, elem) == ZQJS_OK);
    }

    const char *tag_strs[3] = { "alpha", "Beta", "gamma" };
    for (uint32_t i = 0; i < 3; i++) {
        zqjs_handle elem = ZQJS_HANDLE_NULL;
        assert(make_ascii_string(rt, tag_strs[i], &elem) == ZQJS_OK);
        assert(zqjs_handle_set_index(rt, tags, i, elem, &fail) == ZQJS_OK);
        assert(zqjs_handle_release(rt, elem) == ZQJS_OK);
    }

    assert(zqjs_handle_set_property(rt, task, "id", 2, id_h, &fail) == ZQJS_OK);
    assert(zqjs_handle_set_property(rt, task, "name", 4, name_h, &fail) == ZQJS_OK);
    assert(zqjs_handle_set_property(rt, task, "values", 6, vals, &fail) == ZQJS_OK);
    assert(zqjs_handle_set_property(rt, task, "tags", 4, tags, &fail) == ZQJS_OK);

    assert(zqjs_handle_release(rt, id_h) == ZQJS_OK);
    assert(zqjs_handle_release(rt, name_h) == ZQJS_OK);
    assert(zqjs_handle_release(rt, vals) == ZQJS_OK);
    assert(zqjs_handle_release(rt, tags) == ZQJS_OK);

    out->has_result = true;
    out->result = task;
    return ZQJS_OK;
}

/* submitOutput(pluginName, { score: number, summary: string }) */
static zqjs_status native_submit_output(
    zqjs_runtime *rt,
    void *raw_ctx,
    const zqjs_handle *opt_this,
    const zqjs_handle *args,
    size_t argc,
    zqjs_native_out *out
) {
    (void)opt_this;
    (void)out;
    host_ctx *ctx = (host_ctx *)raw_ctx;
    if (argc < 2) return throw_type(rt, "submitOutput expects (name, obj)");

    char pname[64];
    read_ascii_string(rt, args[0], pname, sizeof(pname));
    plugin_record *rec = find_record(ctx, pname);
    if (!rec) return throw_type(rt, "unknown plugin");

    zqjs_failure fail;
    zqjs_handle score_h = ZQJS_HANDLE_NULL;
    zqjs_handle sum_h = ZQJS_HANDLE_NULL;
    assert(zqjs_handle_get_property(rt, args[1], "score", 5, &fail, &score_h) == ZQJS_OK);
    assert(zqjs_handle_get_property(rt, args[1], "summary", 7, &fail, &sum_h) == ZQJS_OK);

    double score = 0.0;
    assert(zqjs_handle_number(rt, score_h, &score) == ZQJS_OK);
    rec->num_out = score;
    read_ascii_string(rt, sum_h, rec->text_out, sizeof(rec->text_out));
    rec->submitted = true;

    assert(zqjs_handle_release(rt, score_h) == ZQJS_OK);
    assert(zqjs_handle_release(rt, sum_h) == ZQJS_OK);
    return ZQJS_OK;
}

typedef struct plugin_slot {
    const char *name;
    const char *source;
    zqjs_program *prog;
    zqjs_execution *exec;
    plugin_state state;
    uint32_t slices;
    zqjs_status last_status;
    zqjs_failure last_fail;
} plugin_slot;

static void destroy_slots(zqjs_runtime *rt, plugin_slot *slots, size_t count) {
    (void)rt;
    for (size_t i = 0; i < count; i++) {
        if (slots[i].exec) {
            assert(zqjs_execution_destroy(slots[i].exec) == ZQJS_OK);
            slots[i].exec = NULL;
        }
        if (slots[i].prog) {
            assert(zqjs_program_destroy(slots[i].prog) == ZQJS_OK);
            slots[i].prog = NULL;
        }
    }
}

static void run_cooperative_batch(double *out_stats_sample) {
    assert((zqjs_abi_version() >> 16) == ZQJS_ABI_MAJOR);

    zqjs_options opts = zqjs_options_default();
    opts.limits.max_heap_bytes = 8u * 1024u * 1024u;
    opts.limits.max_steps = 100000ull;
    opts.random_seed = 0x123456789abcdef0ull;
    opts.output_fn = on_print;

    zqjs_runtime *rt = NULL;
    assert(zqjs_runtime_create(&opts, &rt) == ZQJS_OK);

    host_ctx ctx = { .count = 4 };
    ctx.records[0] = (plugin_record){ .name = "scorer" };
    ctx.records[1] = (plugin_record){ .name = "tagger" };
    ctx.records[2] = (plugin_record){ .name = "stats" };
    ctx.records[3] = (plugin_record){ .name = "bad_plugin" };

    assert(zqjs_runtime_define_global_function(rt, "fetchTask", 9, native_fetch_task, &ctx) == ZQJS_OK);
    assert(zqjs_runtime_define_global_function(rt, "submitOutput", 12, native_submit_output, &ctx) == ZQJS_OK);

    const char *src_scorer =
        "let t = fetchTask('scorer');\n"
        "let roots = [];\n"
        "for (let i = 0; i < t.values.length; i++) roots.push(Math.sqrt(t.values[i]));\n"
        "let recovered = 0;\n"
        "try { throw 'guard-check'; } catch (e) { if (('' + e).includes('guard')) recovered = 1; }\n"
        "let top = roots.slice(1);\n"
        "let total = Math.round(top[0] + top[1] + roots[0] + recovered);\n"
        "submitOutput(t.name, { score: total, summary: 'SCORER:' + Math.max(roots[0], roots[2]) });\n";

    const char *src_tagger =
        "let t = fetchTask('tagger');\n"
        "let norm = [];\n"
        "for (let i = 0; i < t.tags.length; i++) norm.push(t.tags[i].toUpperCase());\n"
        "let hasBeta = norm.includes('BETA') && norm.indexOf('BETA') === 1;\n"
        "let joined = norm.slice(0, 2).join('+');\n"
        "submitOutput(t.name, { score: joined.slice(0, 5).indexOf('A') === 0 ? 1 : 0, summary: joined + ':' + hasBeta });\n";

    const char *src_stats =
        "let t = fetchTask('stats');\n"
        "let acc = 0;\n"
        "for (let i = 0; i < 6; i++) acc = acc + Math.floor(Math.random() * 100);\n"
        "let h = Math.hypot(3, 4);\n"
        "let m = Math.imul(6, 7);\n"
        "submitOutput(t.name, { score: acc + h + m, summary: 'STATS:' + t.id });\n";

    const char *src_bad =
        "let t = fetchTask('bad_plugin');\n"
        "let spin = 0;\n"
        "for (let i = 0; i < 20; i++) spin += i;\n"
        "throw 'plugin-crashed:' + t.name;\n";

    plugin_slot slots[MAX_PLUGINS] = {
        { .name = "scorer", .source = src_scorer },
        { .name = "tagger", .source = src_tagger },
        { .name = "stats", .source = src_stats },
        { .name = "bad_plugin", .source = src_bad },
    };

    for (size_t i = 0; i < MAX_PLUGINS; i++) {
        zqjs_diagnostic diag;
        assert(zqjs_runtime_compile(
                   rt, slots[i].name, strlen(slots[i].name),
                   slots[i].source, strlen(slots[i].source), &diag, &slots[i].prog) == ZQJS_OK);
        assert(zqjs_runtime_start(rt, slots[i].prog, &slots[i].exec) == ZQJS_OK);
        slots[i].state = PLUGIN_SUSPENDED;
    }

    for (int round = 0; round < MAX_ROUNDS; round++) {
        size_t active = 0;
        for (size_t i = 0; i < MAX_PLUGINS; i++) {
            if (slots[i].state != PLUGIN_SUSPENDED) continue;
            active++;
            slots[i].slices++;
            zqjs_status st = zqjs_execution_resume(slots[i].exec, SLICE_STEPS, &slots[i].last_fail);
            slots[i].last_status = st;
            if (st == ZQJS_STATUS_FINISHED) {
                slots[i].state = PLUGIN_FINISHED;
            } else if (st != ZQJS_STATUS_SUSPENDED) {
                slots[i].state = PLUGIN_FAULTED;
            }
        }
        if (active == 0) break;
    }

    /* All 3 healthy plugins finished across multiple slices; bad_plugin faulted after suspending */
    assert(slots[0].state == PLUGIN_FINISHED && slots[0].slices >= 2);
    assert(slots[1].state == PLUGIN_FINISHED && slots[1].slices >= 2);
    assert(slots[2].state == PLUGIN_FINISHED && slots[2].slices >= 2);
    assert(slots[3].state == PLUGIN_FAULTED && slots[3].slices >= 2);
    assert(slots[3].last_status == ZQJS_ERR_THROWN);
    assert(slots[3].last_fail.kind == ZQJS_FAILURE_THROWN);

    /* Latched fault guarantee: resuming a faulted execution returns the same error & failure */
    zqjs_failure latched_fail;
    assert(zqjs_execution_resume(slots[3].exec, SLICE_STEPS, &latched_fail) == ZQJS_ERR_THROWN);
    assert(latched_fail.kind == ZQJS_FAILURE_THROWN);
    assert(strcmp(latched_fail.message, slots[3].last_fail.message) == 0);

    assert(ctx.records[0].submitted && ctx.records[0].num_out == 13.0);
    assert(strcmp(ctx.records[0].text_out, "SCORER:5") == 0);
    assert(ctx.records[1].submitted && ctx.records[1].num_out == 1.0);
    assert(strcmp(ctx.records[1].text_out, "ALPHA+BETA:true") == 0);
    assert(ctx.records[2].submitted);
    assert(strcmp(ctx.records[2].text_out, "STATS:101") == 0);
    assert(!ctx.records[3].submitted);

    *out_stats_sample = ctx.records[2].num_out;

    destroy_slots(rt, slots, MAX_PLUGINS);
    assert(zqjs_runtime_collect_garbage(rt) == ZQJS_OK);
    assert(zqjs_runtime_destroy(rt) == ZQJS_OK);
}

static void test_shared_runtime_step_limit(void) {
    zqjs_options opts = zqjs_options_default();
    opts.limits.max_steps = 400ull;

    zqjs_runtime *rt = NULL;
    assert(zqjs_runtime_create(&opts, &rt) == ZQJS_OK);

    host_ctx ctx = { .count = 1 };
    ctx.records[0] = (plugin_record){ .name = "healthy" };
    assert(zqjs_runtime_define_global_function(rt, "fetchTask", 9, native_fetch_task, &ctx) == ZQJS_OK);
    assert(zqjs_runtime_define_global_function(rt, "submitOutput", 12, native_submit_output, &ctx) == ZQJS_OK);

    const char *src_ok =
        "let t = fetchTask('healthy');\n"
        "let s = 0; for (let i = 0; i < 10; i++) s += i;\n"
        "submitOutput(t.name, { score: s, summary: 'OK' });\n";
    const char *src_loop = "let x = 0; while (true) { x = x + 1; }\n";

    plugin_slot slots[2] = {
        { .name = "healthy", .source = src_ok },
        { .name = "runaway", .source = src_loop },
    };
    for (size_t i = 0; i < 2; i++) {
        zqjs_diagnostic diag;
        assert(zqjs_runtime_compile(
                   rt, slots[i].name, strlen(slots[i].name),
                   slots[i].source, strlen(slots[i].source), &diag, &slots[i].prog) == ZQJS_OK);
        assert(zqjs_runtime_start(rt, slots[i].prog, &slots[i].exec) == ZQJS_OK);
        slots[i].state = PLUGIN_SUSPENDED;
    }

    for (int round = 0; round < 32; round++) {
        size_t active = 0;
        for (size_t i = 0; i < 2; i++) {
            if (slots[i].state != PLUGIN_SUSPENDED) continue;
            active++;
            zqjs_status st = zqjs_execution_resume(slots[i].exec, 50ull, &slots[i].last_fail);
            slots[i].last_status = st;
            if (st == ZQJS_STATUS_FINISHED) slots[i].state = PLUGIN_FINISHED;
            else if (st != ZQJS_STATUS_SUSPENDED) slots[i].state = PLUGIN_FAULTED;
        }
        if (active == 0) break;
    }

    assert(slots[0].state == PLUGIN_FINISHED && ctx.records[0].submitted && ctx.records[0].num_out == 45.0);
    assert(slots[1].state == PLUGIN_FAULTED);
    assert(slots[1].last_status == ZQJS_ERR_LIMIT_EXCEEDED);
    assert(slots[1].last_fail.kind == ZQJS_FAILURE_LIMIT);
    assert(slots[1].last_fail.limit == ZQJS_LIMIT_STEPS);

    destroy_slots(rt, slots, 2);
    assert(zqjs_runtime_collect_garbage(rt) == ZQJS_OK);
    assert(zqjs_runtime_destroy(rt) == ZQJS_OK);
}

static void test_isolated_runtime_heap_limit_recovery(void) {
    zqjs_options opts = zqjs_options_default();
    opts.limits.max_heap_bytes = 128u * 1024u;
    opts.limits.nursery_bytes = 16u * 1024u;

    zqjs_runtime *rt_iso = NULL;
    assert(zqjs_runtime_create(&opts, &rt_iso) == ZQJS_OK);

    const char *oom_src = "let a = []; while (true) { a.push('chunk-' + a.length); }\n";
    zqjs_diagnostic diag;
    zqjs_program *p_oom = NULL;
    assert(zqjs_runtime_compile(rt_iso, "oom.js", 6, oom_src, strlen(oom_src), &diag, &p_oom) == ZQJS_OK);

    zqjs_execution *ex_oom = NULL;
    assert(zqjs_runtime_start(rt_iso, p_oom, &ex_oom) == ZQJS_OK);

    zqjs_failure fail;
    zqjs_status st = ZQJS_STATUS_SUSPENDED;
    while (st == ZQJS_STATUS_SUSPENDED) {
        st = zqjs_execution_resume(ex_oom, 100ull, &fail);
    }
    assert(st == ZQJS_ERR_LIMIT_EXCEEDED);
    assert(fail.kind == ZQJS_FAILURE_LIMIT);
    assert(fail.limit == ZQJS_LIMIT_HEAP_BYTES);

    assert(zqjs_execution_destroy(ex_oom) == ZQJS_OK);
    assert(zqjs_program_destroy(p_oom) == ZQJS_OK);
    assert(zqjs_runtime_collect_garbage(rt_iso) == ZQJS_OK);

    /* Isolated runtime stays usable after execution teardown and GC */
    const char *ok_src = "let x = Math.round(3.6); if (x !== 4) throw 'bad';\n";
    zqjs_program *p_ok = NULL;
    assert(zqjs_runtime_compile(rt_iso, "ok.js", 5, ok_src, strlen(ok_src), &diag, &p_ok) == ZQJS_OK);
    assert(zqjs_runtime_run(rt_iso, p_ok, &fail) == ZQJS_OK);
    assert(zqjs_program_destroy(p_ok) == ZQJS_OK);
    assert(zqjs_runtime_destroy(rt_iso) == ZQJS_OK);
}

static void run_one_cycle(zqjs_runtime *rt, host_ctx *ctx) {
    const char *s1 = "let t = fetchTask('a'); submitOutput(t.name, { score: t.values[0] + 1, summary: 'A' });";
    const char *s2 = "let t = fetchTask('b'); submitOutput(t.name, { score: t.values[1] + 2, summary: 'B' });";
    plugin_slot slots[2] = {
        { .name = "a", .source = s1 },
        { .name = "b", .source = s2 },
    };
    for (size_t i = 0; i < 2; i++) {
        zqjs_diagnostic diag;
        assert(zqjs_runtime_compile(rt, slots[i].name, 1, slots[i].source, strlen(slots[i].source), &diag, &slots[i].prog) == ZQJS_OK);
        assert(zqjs_runtime_start(rt, slots[i].prog, &slots[i].exec) == ZQJS_OK);
        slots[i].state = PLUGIN_SUSPENDED;
    }
    for (int r = 0; r < 32; r++) {
        size_t active = 0;
        for (size_t i = 0; i < 2; i++) {
            if (slots[i].state != PLUGIN_SUSPENDED) continue;
            active++;
            zqjs_status st = zqjs_execution_resume(slots[i].exec, 32ull, &slots[i].last_fail);
            if (st == ZQJS_STATUS_FINISHED) slots[i].state = PLUGIN_FINISHED;
            else assert(st == ZQJS_STATUS_SUSPENDED);
        }
        if (active == 0) break;
    }
    assert(ctx->records[0].submitted && ctx->records[0].num_out == 10.0);
    assert(ctx->records[1].submitted && ctx->records[1].num_out == 18.0);
    destroy_slots(rt, slots, 2);
}

static void test_repeated_cycles_memory_stability(void) {
    zqjs_options opts = zqjs_options_default();
    opts.limits.max_heap_bytes = 4u * 1024u * 1024u;
    zqjs_runtime *rt = NULL;
    assert(zqjs_runtime_create(&opts, &rt) == ZQJS_OK);

    host_ctx ctx = { .count = 2 };
    ctx.records[0] = (plugin_record){ .name = "a" };
    ctx.records[1] = (plugin_record){ .name = "b" };
    assert(zqjs_runtime_define_global_function(rt, "fetchTask", 9, native_fetch_task, &ctx) == ZQJS_OK);
    assert(zqjs_runtime_define_global_function(rt, "submitOutput", 12, native_submit_output, &ctx) == ZQJS_OK);

    /* Warm up atom/realm/handle-table capacity with one cycle, then verify zero handle/heap growth across 20 cycles */
    run_one_cycle(rt, &ctx);
    assert(zqjs_runtime_collect_garbage(rt) == ZQJS_OK);
    zqjs_memory base_mem;
    assert(zqjs_runtime_memory(rt, &base_mem) == ZQJS_OK);

    for (int i = 0; i < 20; i++) {
        ctx.records[0].submitted = false;
        ctx.records[1].submitted = false;
        run_one_cycle(rt, &ctx);
    }
    assert(zqjs_runtime_collect_garbage(rt) == ZQJS_OK);
    zqjs_memory end_mem;
    assert(zqjs_runtime_memory(rt, &end_mem) == ZQJS_OK);
    assert(end_mem.handle_bytes == base_mem.handle_bytes);
    assert(end_mem.bytes <= base_mem.bytes + 256u);

    assert(zqjs_runtime_destroy(rt) == ZQJS_OK);
}

int main(void) {
    double sample1 = 0.0;
    double sample2 = 0.0;
    run_cooperative_batch(&sample1);
    run_cooperative_batch(&sample2);
    assert(sample1 == sample2);

    test_shared_runtime_step_limit();
    test_isolated_runtime_heap_limit_recovery();
    test_repeated_cycles_memory_stability();

    printf("plugin_host ok (deterministic stats=%.0f)\n", sample1);
    return 0;
}
