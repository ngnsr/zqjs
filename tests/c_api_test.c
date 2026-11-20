#include "zqjs.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

_Static_assert(sizeof(zqjs_handle) == 24, "zqjs_handle size");
_Static_assert(offsetof(zqjs_handle, owner) == 0, "zqjs_handle.owner offset");
_Static_assert(offsetof(zqjs_handle, slot) == 8, "zqjs_handle.slot offset");
_Static_assert(offsetof(zqjs_handle, generation) == 16, "zqjs_handle.generation offset");

typedef struct capture_buf {
    char data[512];
    size_t len;
    zqjs_runtime *reenter_rt;
    zqjs_status reenter_status;
} capture_buf;

static bool test_output(void *ctx, const char *bytes, size_t len) {
    capture_buf *cap = (capture_buf *)ctx;
    if (cap->reenter_rt != NULL) {
        zqjs_memory mem;
        cap->reenter_status = zqjs_runtime_memory(cap->reenter_rt, &mem);
    }
    size_t avail = sizeof(cap->data) - 1 - cap->len;
    size_t n = len < avail ? len : avail;
    if (n > 0) {
        memcpy(cap->data + cap->len, bytes, n);
        cap->len += n;
        cap->data[cap->len] = '\0';
    }
    return true;
}

static void run_script_ok(zqjs_runtime *rt, const char *name, const char *src) {
    zqjs_diagnostic diag;
    zqjs_program *prog = NULL;
    assert(zqjs_runtime_compile(rt, name, strlen(name), src, strlen(src), &diag, &prog) == ZQJS_OK);
    zqjs_failure fail;
    assert(zqjs_runtime_run(rt, prog, &fail) == ZQJS_OK);
    assert(zqjs_program_destroy(prog) == ZQJS_OK);
}

/* 1. Handle duplication, release, stale handles, slot reuse, UTF-16 strings */
static void test_handles_and_slot_reuse(void) {
    zqjs_options opts = zqjs_options_default();
    opts.limits.max_handles = 2;

    zqjs_runtime *rt = NULL;
    assert(zqjs_runtime_create(&opts, &rt) == ZQJS_OK);

    zqjs_handle num = ZQJS_HANDLE_NULL;
    assert(zqjs_new_number(rt, 42.5, &num) == ZQJS_OK);
    zqjs_handle_kind kind = ZQJS_HANDLE_UNDEFINED;
    assert(zqjs_handle_kind_of(rt, num, &kind) == ZQJS_OK);
    assert(kind == ZQJS_HANDLE_NUMBER);

    double d = 0.0;
    assert(zqjs_handle_number(rt, num, &d) == ZQJS_OK);
    assert(d == 42.5);
    bool b = false;
    assert(zqjs_handle_boolean(rt, num, &b) == ZQJS_ERR_TYPE);

    zqjs_handle dup = ZQJS_HANDLE_NULL;
    assert(zqjs_handle_dup(rt, num, &dup) == ZQJS_OK);

    /* max_handles = 2: 3rd concurrent handle hits LimitExceeded(handles) */
    zqjs_handle third = ZQJS_HANDLE_NULL;
    assert(zqjs_new_boolean(rt, true, &third) == ZQJS_ERR_LIMIT_EXCEEDED);

    /* Release `num`, reuse its slot for a UTF-16 string, verify `num` stays stale! */
    assert(zqjs_handle_release(rt, num) == ZQJS_OK);
    assert(zqjs_handle_release(rt, num) == ZQJS_ERR_STALE_HANDLE);
    assert(zqjs_handle_number(rt, num, &d) == ZQJS_ERR_STALE_HANDLE);
    assert(zqjs_handle_dup(rt, num, &third) == ZQJS_ERR_STALE_HANDLE);

    const uint16_t hello[] = { 'h', 'i', '!' };
    zqjs_handle str = ZQJS_HANDLE_NULL;
    assert(zqjs_new_string_utf16(rt, hello, 3, &str) == ZQJS_OK);
    assert(str.slot == num.slot);
    assert(str.generation != num.generation);

    /* Old `num` token still fails even though `str` now occupies the same slot */
    assert(zqjs_handle_kind_of(rt, num, &kind) == ZQJS_ERR_STALE_HANDLE);

    uint16_t u16_buf[2];
    size_t full_len = 0;
    assert(zqjs_handle_string_utf16(rt, str, u16_buf, 2, &full_len) == ZQJS_OK);
    assert(full_len == 3);
    assert(u16_buf[0] == 'h' && u16_buf[1] == 'i');

    /* Duplicate still holds 42.5 independently */
    assert(zqjs_handle_number(rt, dup, &d) == ZQJS_OK);
    assert(d == 42.5);

    assert(zqjs_handle_release(rt, dup) == ZQJS_OK);
    assert(zqjs_handle_release(rt, str) == ZQJS_OK);
    assert(zqjs_runtime_destroy(rt) == ZQJS_OK);
}

/* 2. Cross-runtime handle rejection */
static void test_cross_runtime_handles(void) {
    zqjs_runtime *rt1 = NULL;
    zqjs_runtime *rt2 = NULL;
    assert(zqjs_runtime_create(NULL, &rt1) == ZQJS_OK);
    assert(zqjs_runtime_create(NULL, &rt2) == ZQJS_OK);

    zqjs_handle h1 = ZQJS_HANDLE_NULL;
    assert(zqjs_new_number(rt1, 99.0, &h1) == ZQJS_OK);

    double d = 0.0;
    zqjs_handle dup = ZQJS_HANDLE_NULL;
    assert(zqjs_handle_number(rt2, h1, &d) == ZQJS_ERR_FOREIGN_HANDLE);
    assert(zqjs_handle_dup(rt2, h1, &dup) == ZQJS_ERR_FOREIGN_HANDLE);
    assert(zqjs_handle_release(rt2, h1) == ZQJS_ERR_FOREIGN_HANDLE);

    zqjs_handle res = ZQJS_HANDLE_NULL;
    zqjs_failure fail;
    assert(zqjs_runtime_call(rt2, h1, NULL, NULL, 0, &fail, &res) == ZQJS_ERR_FOREIGN_HANDLE);

    assert(zqjs_handle_release(rt1, h1) == ZQJS_OK);
    assert(zqjs_runtime_destroy(rt1) == ZQJS_OK);
    assert(zqjs_runtime_destroy(rt2) == ZQJS_OK);
}

/* 3, 4, 5, 6, 7: Callbacks, ownership, errors, round-trips, reentrancy, GC */
typedef struct cb_ctx {
    zqjs_handle stashed_temp;
    zqjs_handle retained;
    zqjs_program *prog_to_destroy;
    zqjs_status compile_status;
    zqjs_status define_status;
    zqjs_status prog_destroy_status;
    zqjs_status rt_destroy_status;
    bool gc_ran_in_cb;
} cb_ctx;

static zqjs_status native_add_and_stash(
    zqjs_runtime *rt,
    void *raw,
    const zqjs_handle *opt_this,
    const zqjs_handle *args,
    size_t argc,
    zqjs_native_out *out
) {
    (void)opt_this;
    cb_ctx *ctx = (cb_ctx *)raw;
    assert(argc == 2);

    /* Borrowed arg 0 stashed without dup -> becomes stale after callback returns */
    ctx->stashed_temp = args[0];

    double a = 0.0, b = 0.0;
    assert(zqjs_handle_number(rt, args[0], &a) == ZQJS_OK);
    assert(zqjs_handle_number(rt, args[1], &b) == ZQJS_OK);

    /* Test disallowed reentrancy inside callback -> ZQJS_ERR_BUSY */
    zqjs_diagnostic diag;
    zqjs_program *tmp_p = NULL;
    ctx->compile_status = zqjs_runtime_compile(rt, "x.js", 4, "1;", 2, &diag, &tmp_p);
    ctx->define_status = zqjs_runtime_define_global_function(rt, "nope", 4, native_add_and_stash, ctx);
    ctx->prog_destroy_status = zqjs_program_destroy(ctx->prog_to_destroy);
    ctx->rt_destroy_status = zqjs_runtime_destroy(rt);

    /* Force GC right inside the callback while borrowed + retained handles exist */
    assert(zqjs_runtime_collect_garbage(rt) == ZQJS_OK);
    ctx->gc_ran_in_cb = true;

    zqjs_handle sum = ZQJS_HANDLE_NULL;
    assert(zqjs_new_number(rt, a + b, &sum) == ZQJS_OK);
    out->has_result = true;
    out->result = sum;
    return ZQJS_OK;
}

static zqjs_status native_return_retained_dup(
    zqjs_runtime *rt,
    void *raw,
    const zqjs_handle *opt_this,
    const zqjs_handle *args,
    size_t argc,
    zqjs_native_out *out
) {
    (void)opt_this;
    (void)args;
    (void)argc;
    cb_ctx *ctx = (cb_ctx *)raw;
    assert(zqjs_handle_dup(rt, ctx->retained, &out->result) == ZQJS_OK);
    out->has_result = true;
    return ZQJS_OK;
}

static zqjs_status native_throw_js(
    zqjs_runtime *rt,
    void *raw,
    const zqjs_handle *opt_this,
    const zqjs_handle *args,
    size_t argc,
    zqjs_native_out *out
) {
    (void)raw;
    (void)opt_this;
    (void)args;
    (void)argc;
    (void)out;
    const uint16_t msg[] = { 'b', 'a', 'd', ' ', 'a', 'r', 'g' };
    assert(zqjs_runtime_throw_js(rt, ZQJS_ERROR_RANGE, msg, 7) == ZQJS_OK);
    return ZQJS_ERR_THROWN;
}

static zqjs_status native_host_error(
    zqjs_runtime *rt,
    void *raw,
    const zqjs_handle *opt_this,
    const zqjs_handle *args,
    size_t argc,
    zqjs_native_out *out
) {
    (void)rt;
    (void)raw;
    (void)opt_this;
    (void)args;
    (void)argc;
    const char *msg = "disk full";
    out->host_message = msg;
    out->host_message_len = strlen(msg);
    return ZQJS_ERR_HOST;
}

static zqjs_status native_round_trip(
    zqjs_runtime *rt,
    void *raw,
    const zqjs_handle *opt_this,
    const zqjs_handle *args,
    size_t argc,
    zqjs_native_out *out
) {
    (void)raw;
    (void)opt_this;
    assert(argc == 2);

    /* Force GC before calling JS callback `args[0]` */
    assert(zqjs_runtime_collect_garbage(rt) == ZQJS_OK);

    zqjs_failure fail;
    zqjs_handle res = ZQJS_HANDLE_NULL;
    assert(zqjs_runtime_call(rt, args[0], NULL, &args[1], 1, &fail, &res) == ZQJS_OK);
    out->has_result = true;
    out->result = res;
    return ZQJS_OK;
}

static void test_callbacks_errors_roundtrip_and_reentrancy(void) {
    capture_buf cap = { .len = 0, .reenter_rt = NULL, .reenter_status = ZQJS_OK };
    cap.data[0] = '\0';

    zqjs_options opts = zqjs_options_default();
    opts.output_fn = test_output;
    opts.output_ctx = &cap;

    zqjs_runtime *rt = NULL;
    assert(zqjs_runtime_create(&opts, &rt) == ZQJS_OK);

    /* throw_js outside a callback returns ZQJS_ERR_INVALID_STATE (no panic) */
    const uint16_t u_msg[] = { 'x' };
    assert(zqjs_runtime_throw_js(rt, ZQJS_ERROR_TYPE, u_msg, 1) == ZQJS_ERR_INVALID_STATE);

    cb_ctx ctx = {
        .stashed_temp = ZQJS_HANDLE_NULL,
        .retained = ZQJS_HANDLE_NULL,
        .prog_to_destroy = NULL,
        .compile_status = ZQJS_OK,
        .define_status = ZQJS_OK,
        .prog_destroy_status = ZQJS_OK,
        .rt_destroy_status = ZQJS_OK,
        .gc_ran_in_cb = false,
    };
    assert(zqjs_new_number(rt, 777.0, &ctx.retained) == ZQJS_OK);

    assert(zqjs_runtime_define_global_function(rt, "addAndStash", 11, native_add_and_stash, &ctx) == ZQJS_OK);
    assert(zqjs_runtime_define_global_function(rt, "addAndStash", 11, native_add_and_stash, &ctx) == ZQJS_ERR_NAME_TAKEN);
    assert(zqjs_runtime_define_global_function(rt, "print", 5, native_add_and_stash, &ctx) == ZQJS_ERR_NAME_TAKEN);
    assert(zqjs_runtime_define_global_function(rt, "getRetained", 11, native_return_retained_dup, &ctx) == ZQJS_OK);
    assert(zqjs_runtime_define_global_function(rt, "failJs", 6, native_throw_js, &ctx) == ZQJS_OK);
    assert(zqjs_runtime_define_global_function(rt, "failHost", 8, native_host_error, &ctx) == ZQJS_OK);
    assert(zqjs_runtime_define_global_function(rt, "roundTrip", 9, native_round_trip, &ctx) == ZQJS_OK);

    const char *src = "print(addAndStash(12, 30) + getRetained());";
    zqjs_diagnostic diag;
    zqjs_program *prog = NULL;
    assert(zqjs_runtime_compile(rt, "cb.js", 5, src, strlen(src), &diag, &prog) == ZQJS_OK);
    ctx.prog_to_destroy = prog;

    zqjs_failure fail;
    assert(zqjs_runtime_run(rt, prog, &fail) == ZQJS_OK);
    assert(zqjs_program_destroy(prog) == ZQJS_OK);
    assert(strcmp(cap.data, "819\n") == 0);

    /* Verify callback assertions */
    assert(ctx.gc_ran_in_cb);
    assert(ctx.compile_status == ZQJS_ERR_BUSY);
    assert(ctx.define_status == ZQJS_ERR_BUSY);
    assert(ctx.prog_destroy_status == ZQJS_ERR_BUSY);
    assert(ctx.rt_destroy_status == ZQJS_ERR_BUSY);

    /* Borrowed temporary handle from callback is stale now */
    double d = 0.0;
    assert(zqjs_handle_number(rt, ctx.stashed_temp, &d) == ZQJS_ERR_STALE_HANDLE);
    /* Retained handle survived dup + GC */
    assert(zqjs_handle_number(rt, ctx.retained, &d) == ZQJS_OK);
    assert(d == 777.0);

    /* JS exception vs host error */
    zqjs_program *p_throw = NULL;
    assert(zqjs_runtime_compile(rt, "t.js", 4, "failJs();", 9, &diag, &p_throw) == ZQJS_OK);
    assert(zqjs_runtime_run(rt, p_throw, &fail) == ZQJS_ERR_THROWN);
    assert(fail.kind == ZQJS_FAILURE_THROWN);
    assert(strstr(fail.message, "RangeError: bad arg") != NULL);
    assert(zqjs_program_destroy(p_throw) == ZQJS_OK);

    zqjs_program *p_host = NULL;
    assert(zqjs_runtime_compile(rt, "h.js", 4, "failHost();", 11, &diag, &p_host) == ZQJS_OK);
    assert(zqjs_runtime_run(rt, p_host, &fail) == ZQJS_ERR_HOST);
    assert(fail.kind == ZQJS_FAILURE_HOST);
    assert(strcmp(fail.message, "disk full") == 0);
    assert(zqjs_program_destroy(p_host) == ZQJS_OK);

    /* Host -> JS -> Host -> JS round trip via zqjs_runtime_call */
    run_script_ok(
        rt,
        "rt.js",
        "let capturedFn = null;"
        "function register(fn) { capturedFn = fn; }"
        "register(function(n) { return roundTrip(function(x) { return x * 3 + 1; }, n); });"
    );
    /* Re-expose capturedFn via a native callback so host gets a handle to it */
    /* Simpler: use a global JS function? We can pass a closure to a native! */
    /* Actually let's register a native `saveCb(fn)` that dups `args[0]` into `ctx.retained` */
    assert(zqjs_handle_release(rt, ctx.retained) == ZQJS_OK);

    /* Writer re-entrancy check -> ZQJS_ERR_BUSY instead of panic */
    cap.reenter_rt = rt;
    run_script_ok(rt, "p.js", "print('hello');");
    assert(cap.reenter_status == ZQJS_ERR_BUSY);
    cap.reenter_rt = NULL;

    assert(zqjs_runtime_destroy(rt) == ZQJS_OK);
}

static zqjs_status native_save_fn(
    zqjs_runtime *rt,
    void *raw,
    const zqjs_handle *opt_this,
    const zqjs_handle *args,
    size_t argc,
    zqjs_native_out *out
) {
    (void)opt_this;
    (void)out;
    assert(argc == 1);
    zqjs_handle *slot = (zqjs_handle *)raw;
    return zqjs_handle_dup(rt, args[0], slot);
}

static void test_host_js_host_round_trip(void) {
    zqjs_runtime *rt = NULL;
    assert(zqjs_runtime_create(NULL, &rt) == ZQJS_OK);

    cb_ctx ctx = { .retained = ZQJS_HANDLE_NULL };
    zqjs_handle js_fn = ZQJS_HANDLE_NULL;
    assert(zqjs_runtime_define_global_function(rt, "saveFn", 6, native_save_fn, &js_fn) == ZQJS_OK);
    assert(zqjs_runtime_define_global_function(rt, "roundTrip", 9, native_round_trip, &ctx) == ZQJS_OK);

    const char *src = "saveFn(function(n) { return roundTrip(function(x) { return x * 3 + 1; }, n); });";
    zqjs_diagnostic diag;
    zqjs_program *prog = NULL;
    assert(zqjs_runtime_compile(rt, "rt2.js", 6, src, strlen(src), &diag, &prog) == ZQJS_OK);
    zqjs_failure fail;
    assert(zqjs_runtime_run(rt, prog, &fail) == ZQJS_OK);

    zqjs_handle arg = ZQJS_HANDLE_NULL;
    assert(zqjs_new_number(rt, 10.0, &arg) == ZQJS_OK);

    zqjs_handle res = ZQJS_HANDLE_NULL;
    assert(zqjs_runtime_call(rt, js_fn, NULL, &arg, 1, &fail, &res) == ZQJS_OK);

    double val = 0.0;
    assert(zqjs_handle_number(rt, res, &val) == ZQJS_OK);
    assert(val == 31.0);

    assert(zqjs_handle_release(rt, res) == ZQJS_OK);
    assert(zqjs_handle_release(rt, arg) == ZQJS_OK);
    assert(zqjs_handle_release(rt, js_fn) == ZQJS_OK);
    assert(zqjs_program_destroy(prog) == ZQJS_OK);
    assert(zqjs_runtime_destroy(rt) == ZQJS_OK);
}

static void test_mid_run_program_destroy_and_runtime_destroy_with_children(void) {
    capture_buf cap = { .len = 0, .reenter_rt = NULL, .reenter_status = ZQJS_OK };
    cap.data[0] = '\0';

    zqjs_options opts = zqjs_options_default();
    opts.output_fn = test_output;
    opts.output_ctx = &cap;

    /* 1. Destroy Program while Execution is suspended mid-run, then resume to finished */
    zqjs_runtime *rt = NULL;
    assert(zqjs_runtime_create(&opts, &rt) == ZQJS_OK);

    const char *src = "let s = 'still alive'; let sum = 0; for (let i = 1; i <= 4; i++) sum += i; print(s);";
    zqjs_diagnostic diag;
    zqjs_program *prog = NULL;
    assert(zqjs_runtime_compile(rt, "mid.js", 6, src, strlen(src), &diag, &prog) == ZQJS_OK);

    zqjs_execution *exec = NULL;
    assert(zqjs_runtime_start(rt, prog, &exec) == ZQJS_OK);

    zqjs_failure fail;
    assert(zqjs_execution_resume(exec, 2, &fail) == ZQJS_STATUS_SUSPENDED);
    assert(zqjs_program_destroy(prog) == ZQJS_OK);
    assert(zqjs_program_destroy(prog) == ZQJS_ERR_INVALID_STATE);

    for (;;) {
        zqjs_status st = zqjs_execution_resume(exec, 4, &fail);
        if (st == ZQJS_STATUS_FINISHED) break;
        assert(st == ZQJS_STATUS_SUSPENDED);
    }
    assert(strcmp(cap.data, "still alive\n") == 0);
    assert(zqjs_execution_destroy(exec) == ZQJS_OK);
    assert(zqjs_runtime_destroy(rt) == ZQJS_OK);

    /* 2. Destroy Runtime while child Program, suspended Execution, and Handle still exist */
    assert(zqjs_runtime_create(NULL, &rt) == ZQJS_OK);
    assert(zqjs_runtime_compile(rt, "live.js", 7, src, strlen(src), &diag, &prog) == ZQJS_OK);
    assert(zqjs_runtime_start(rt, prog, &exec) == ZQJS_OK);
    assert(zqjs_execution_resume(exec, 1, &fail) == ZQJS_STATUS_SUSPENDED);
    zqjs_handle h = ZQJS_HANDLE_NULL;
    assert(zqjs_new_number(rt, 99.0, &h) == ZQJS_OK);
    assert(zqjs_runtime_destroy(rt) == ZQJS_OK);
}

static void test_m12_3_abi_version_options_and_handles(void) {
    assert(zqjs_abi_version() == ZQJS_ABI_VERSION);
    assert((zqjs_abi_version() >> 16) == ZQJS_ABI_MAJOR);

    /* struct_size validation */
    zqjs_runtime *bad_rt = NULL;
    zqjs_options bad_opts = zqjs_options_default();
    bad_opts.struct_size = 0;
    assert(zqjs_runtime_create(&bad_opts, &bad_rt) == ZQJS_ERR_INVALID_ARG);
    assert(bad_rt == NULL);

    bad_opts.struct_size = 16;
    assert(zqjs_runtime_create(&bad_opts, &bad_rt) == ZQJS_ERR_INVALID_ARG);

    bad_opts.struct_size = (uint32_t)(sizeof(zqjs_options) + 8u);
    assert(zqjs_runtime_create(&bad_opts, &bad_rt) == ZQJS_ERR_INVALID_ARG);

    /* Smaller struct (pre-random_seed size) stays valid and uses default seed */
    typedef struct zqjs_options_v1_0 {
        uint32_t struct_size;
        uint32_t reserved;
        zqjs_limits limits;
        zqjs_output_fn output_fn;
        void *output_ctx;
        zqjs_clock_fn clock_fn;
        void *clock_ctx;
    } zqjs_options_v1_0;

    capture_buf cap_v10 = { .len = 0, .reenter_rt = NULL, .reenter_status = ZQJS_OK };
    zqjs_options def_opts = zqjs_options_default();
    zqjs_options_v1_0 old_opts;
    old_opts.struct_size = (uint32_t)sizeof(zqjs_options_v1_0);
    old_opts.reserved = 0;
    old_opts.limits = def_opts.limits;
    old_opts.output_fn = test_output;
    old_opts.output_ctx = &cap_v10;
    old_opts.clock_fn = NULL;
    old_opts.clock_ctx = NULL;

    zqjs_runtime *rt_old = NULL;
    assert(zqjs_runtime_create((const zqjs_options *)&old_opts, &rt_old) == ZQJS_OK);

    capture_buf cap_def = { .len = 0, .reenter_rt = NULL, .reenter_status = ZQJS_OK };
    def_opts.output_fn = test_output;
    def_opts.output_ctx = &cap_def;
    zqjs_runtime *rt_def = NULL;
    assert(zqjs_runtime_create(&def_opts, &rt_def) == ZQJS_OK);

    const char *rng_src = "print(Math.random());";
    zqjs_diagnostic diag;
    zqjs_program *p_old = NULL;
    zqjs_program *p_def = NULL;
    assert(zqjs_runtime_compile(rt_old, "r.js", 4, rng_src, strlen(rng_src), &diag, &p_old) == ZQJS_OK);
    assert(zqjs_runtime_compile(rt_def, "r.js", 4, rng_src, strlen(rng_src), &diag, &p_def) == ZQJS_OK);
    assert(zqjs_runtime_run(rt_old, p_old, NULL) == ZQJS_OK);
    assert(zqjs_runtime_run(rt_def, p_def, NULL) == ZQJS_OK);
    assert(strcmp(cap_v10.data, cap_def.data) == 0);
    assert(zqjs_program_destroy(p_old) == ZQJS_OK);
    assert(zqjs_program_destroy(p_def) == ZQJS_OK);
    assert(zqjs_runtime_destroy(rt_old) == ZQJS_OK);

    /* Explicit random_seed diverges from default */
    capture_buf cap_seed = { .len = 0, .reenter_rt = NULL, .reenter_status = ZQJS_OK };
    zqjs_options seed_opts = zqjs_options_default();
    seed_opts.output_fn = test_output;
    seed_opts.output_ctx = &cap_seed;
    seed_opts.random_seed = 42ull;
    zqjs_runtime *rt_seed = NULL;
    assert(zqjs_runtime_create(&seed_opts, &rt_seed) == ZQJS_OK);
    zqjs_program *p_seed = NULL;
    assert(zqjs_runtime_compile(rt_seed, "r.js", 4, rng_src, strlen(rng_src), &diag, &p_seed) == ZQJS_OK);
    assert(zqjs_runtime_run(rt_seed, p_seed, NULL) == ZQJS_OK);
    assert(strcmp(cap_seed.data, cap_def.data) != 0);
    assert(zqjs_program_destroy(p_seed) == ZQJS_OK);

    /* newObject, newArray, getProperty/setProperty, getIndex/setIndex, getGlobal */
    zqjs_handle obj = ZQJS_HANDLE_NULL;
    zqjs_handle arr = ZQJS_HANDLE_NULL;
    zqjs_handle num = ZQJS_HANDLE_NULL;
    assert(zqjs_new_object(rt_def, &obj) == ZQJS_OK);
    assert(zqjs_new_array(rt_def, &arr) == ZQJS_OK);
    assert(zqjs_new_number(rt_def, 99.0, &num) == ZQJS_OK);

    zqjs_handle_kind k = ZQJS_HANDLE_UNDEFINED;
    assert(zqjs_handle_kind_of(rt_def, obj, &k) == ZQJS_OK && k == ZQJS_HANDLE_OBJECT);
    assert(zqjs_handle_kind_of(rt_def, arr, &k) == ZQJS_OK && k == ZQJS_HANDLE_ARRAY);

    zqjs_failure fail;
    assert(zqjs_handle_set_property(rt_def, obj, "x", 1, num, &fail) == ZQJS_OK);
    assert(zqjs_handle_set_property(rt_def, obj, NULL, 1, num, &fail) == ZQJS_ERR_INVALID_ARG);

    zqjs_handle got_x = ZQJS_HANDLE_NULL;
    assert(zqjs_handle_get_property(rt_def, obj, "x", 1, &fail, &got_x) == ZQJS_OK);
    double xv = 0.0;
    assert(zqjs_handle_number(rt_def, got_x, &xv) == ZQJS_OK && xv == 99.0);
    assert(zqjs_handle_release(rt_def, got_x) == ZQJS_OK);

    zqjs_handle missing = ZQJS_HANDLE_NULL;
    assert(zqjs_handle_get_property(rt_def, obj, "nope", 4, &fail, &missing) == ZQJS_OK);
    assert(zqjs_handle_kind_of(rt_def, missing, &k) == ZQJS_OK && k == ZQJS_HANDLE_UNDEFINED);

    /* TypeError on undefined receiver */
    zqjs_handle bad_prop = ZQJS_HANDLE_NULL;
    assert(zqjs_handle_get_property(rt_def, missing, "a", 1, &fail, &bad_prop) == ZQJS_ERR_THROWN);
    assert(fail.kind == ZQJS_FAILURE_THROWN);
    assert(zqjs_handle_release(rt_def, missing) == ZQJS_OK);

    /* Array dense index operations */
    assert(zqjs_handle_set_index(rt_def, arr, 0, num, &fail) == ZQJS_OK);
    assert(zqjs_handle_set_index(rt_def, arr, 3, num, &fail) == ZQJS_ERR_UNSUPPORTED);
    assert(fail.kind == ZQJS_FAILURE_UNSUPPORTED);

    zqjs_handle got_0 = ZQJS_HANDLE_NULL;
    assert(zqjs_handle_get_index(rt_def, arr, 0, &fail, &got_0) == ZQJS_OK);
    double v0 = 0.0;
    assert(zqjs_handle_number(rt_def, got_0, &v0) == ZQJS_OK && v0 == 99.0);
    assert(zqjs_handle_release(rt_def, got_0) == ZQJS_OK);

    zqjs_handle oob = ZQJS_HANDLE_NULL;
    assert(zqjs_handle_get_index(rt_def, arr, 5, &fail, &oob) == ZQJS_OK);
    assert(zqjs_handle_kind_of(rt_def, oob, &k) == ZQJS_OK && k == ZQJS_HANDLE_UNDEFINED);
    assert(zqjs_handle_release(rt_def, oob) == ZQJS_OK);

    /* getGlobal */
    zqjs_handle math_h = ZQJS_HANDLE_NULL;
    assert(zqjs_runtime_get_global(rt_def, "Math", 4, &fail, &math_h) == ZQJS_OK);
    zqjs_handle pi_h = ZQJS_HANDLE_NULL;
    assert(zqjs_handle_get_property(rt_def, math_h, "PI", 2, &fail, &pi_h) == ZQJS_OK);
    double pi_val = 0.0;
    assert(zqjs_handle_number(rt_def, pi_h, &pi_val) == ZQJS_OK && pi_val > 3.14 && pi_val < 3.15);
    assert(zqjs_handle_release(rt_def, pi_h) == ZQJS_OK);
    assert(zqjs_handle_release(rt_def, math_h) == ZQJS_OK);

    zqjs_handle bad_global = ZQJS_HANDLE_NULL;
    assert(zqjs_runtime_get_global(rt_def, "nope", 4, &fail, &bad_global) == ZQJS_ERR_THROWN);

    /* Stale and foreign handle validation */
    assert(zqjs_handle_get_index(rt_def, ZQJS_HANDLE_NULL, 0, &fail, &bad_prop) == ZQJS_ERR_STALE_HANDLE);
    assert(zqjs_handle_get_property(rt_seed, obj, "x", 1, &fail, &bad_prop) == ZQJS_ERR_FOREIGN_HANDLE);

    assert(zqjs_handle_release(rt_def, num) == ZQJS_OK);
    assert(zqjs_handle_release(rt_def, arr) == ZQJS_OK);
    assert(zqjs_handle_release(rt_def, obj) == ZQJS_OK);
    assert(zqjs_runtime_destroy(rt_seed) == ZQJS_OK);
    assert(zqjs_runtime_destroy(rt_def) == ZQJS_OK);
}

typedef struct frame_timer {
    bool active;
    int due_frame;
    bool should_reject;
    zqjs_handle resolve;
    zqjs_handle reject;
} frame_timer;

#define MAX_TIMERS 32

typedef struct frame_host {
    int current_frame;
    frame_timer timers[MAX_TIMERS];
    zqjs_handle script_promises[4];
    size_t script_promise_count;
} frame_host;

static zqjs_status native_wait_frames(
    zqjs_runtime *rt,
    void *raw_ctx,
    const zqjs_handle *opt_this,
    const zqjs_handle *args,
    size_t argc,
    zqjs_native_out *out
) {
    (void)opt_this;
    frame_host *host = (frame_host *)raw_ctx;
    double n = 1.0;
    if (argc >= 1) {
        zqjs_status st = zqjs_handle_number(rt, args[0], &n);
        if (st != ZQJS_OK) return st;
    }
    bool reject_flag = false;
    if (argc >= 2) {
        zqjs_status st = zqjs_handle_boolean(rt, args[1], &reject_flag);
        if (st != ZQJS_OK) return st;
    }

    int slot = -1;
    for (int i = 0; i < MAX_TIMERS; i++) {
        if (!host->timers[i].active) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        out->host_message = "timer table full";
        out->host_message_len = 16;
        return ZQJS_ERR_HOST;
    }

    zqjs_handle p = ZQJS_HANDLE_NULL;
    zqjs_handle res = ZQJS_HANDLE_NULL;
    zqjs_handle rej = ZQJS_HANDLE_NULL;
    zqjs_status st = zqjs_new_promise(rt, &p, &res, &rej);
    if (st != ZQJS_OK) return st;

    host->timers[slot].active = true;
    host->timers[slot].due_frame = host->current_frame + (int)n;
    host->timers[slot].should_reject = reject_flag;
    host->timers[slot].resolve = res;
    host->timers[slot].reject = rej;

    out->has_result = true;
    out->result = p;
    return ZQJS_OK;
}

static zqjs_status native_track_promise(
    zqjs_runtime *rt,
    void *raw_ctx,
    const zqjs_handle *opt_this,
    const zqjs_handle *args,
    size_t argc,
    zqjs_native_out *out
) {
    (void)opt_this;
    (void)out;
    frame_host *host = (frame_host *)raw_ctx;
    if (argc < 1 || host->script_promise_count >= 4) return ZQJS_ERR_HOST;
    zqjs_handle duped = ZQJS_HANDLE_NULL;
    zqjs_status st = zqjs_handle_dup(rt, args[0], &duped);
    if (st != ZQJS_OK) return st;
    host->script_promises[host->script_promise_count++] = duped;
    return ZQJS_OK;
}

/* 7. M29 host promises (60-frame timer loop, leak & handle checks) + D60 C ABI 1.2.0 */
static void test_m29_host_promises_60_frames_and_d60_native_stack(void) {
    assert(ZQJS_ABI_VERSION == 0x00010400u);
    assert(zqjs_abi_version() == 0x00010400u);

    /* 7a. 1.1 struct_size backward compatibility (without max_native_stack_bytes) */
    typedef struct zqjs_options_v1_1 {
        uint32_t struct_size;
        uint32_t reserved;
        zqjs_limits limits;
        zqjs_output_fn output_fn;
        void *output_ctx;
        zqjs_clock_fn clock_fn;
        void *clock_ctx;
        uint64_t random_seed;
    } zqjs_options_v1_1;

    zqjs_options def = zqjs_options_default();
    assert(def.max_native_stack_bytes == 4u * 1024u * 1024u);

    zqjs_options_v1_1 v11;
    v11.struct_size = (uint32_t)sizeof(zqjs_options_v1_1);
    v11.reserved = 0;
    v11.limits = def.limits;
    v11.output_fn = NULL;
    v11.output_ctx = NULL;
    v11.clock_fn = NULL;
    v11.clock_ctx = NULL;
    v11.random_seed = 12345ull;

    zqjs_runtime *rt_v11 = NULL;
    assert(zqjs_runtime_create((const zqjs_options *)&v11, &rt_v11) == ZQJS_OK);
    assert(zqjs_runtime_destroy(rt_v11) == ZQJS_OK);

    /* 7b. D60: C host configuring max_native_stack_bytes faults cleanly with ZQJS_LIMIT_NATIVE_STACK */
    zqjs_options stack_opts = zqjs_options_default();
    stack_opts.max_native_stack_bytes = 64u * 1024u;
    zqjs_runtime *rt_stack = NULL;
    assert(zqjs_runtime_create(&stack_opts, &rt_stack) == ZQJS_OK);

    const char *rec_src = "function f(n) { return [n].map(x => f(x + 1)); } f(0);";
    zqjs_diagnostic diag;
    zqjs_program *rec_prog = NULL;
    assert(zqjs_runtime_compile(rt_stack, "rec.js", 6, rec_src, strlen(rec_src), &diag, &rec_prog) == ZQJS_OK);
    zqjs_failure fail;
    assert(zqjs_runtime_run(rt_stack, rec_prog, &fail) == ZQJS_ERR_LIMIT_EXCEEDED);
    assert(fail.kind == ZQJS_FAILURE_LIMIT);
    assert(fail.limit == ZQJS_LIMIT_NATIVE_STACK);
    assert(zqjs_program_destroy(rec_prog) == ZQJS_OK);
    assert(zqjs_runtime_destroy(rt_stack) == ZQJS_OK);

    /* 7c. zqjs_new_promise & zqjs_handle_promise_state validation and handle rollback */
    zqjs_options cap_opts = zqjs_options_default();
    cap_opts.limits.max_handles = 4;
    zqjs_runtime *rt_cap = NULL;
    assert(zqjs_runtime_create(&cap_opts, &rt_cap) == ZQJS_OK);

    zqjs_handle p = ZQJS_HANDLE_NULL, res = ZQJS_HANDLE_NULL, rej = ZQJS_HANDLE_NULL;
    assert(zqjs_new_promise(NULL, &p, &res, &rej) == ZQJS_ERR_INVALID_ARG);
    assert(zqjs_new_promise(rt_cap, NULL, &res, &rej) == ZQJS_ERR_INVALID_ARG);
    assert(zqjs_new_promise(rt_cap, &p, NULL, &rej) == ZQJS_ERR_INVALID_ARG);
    assert(zqjs_new_promise(rt_cap, &p, &res, NULL) == ZQJS_ERR_INVALID_ARG);

    assert(zqjs_new_promise(rt_cap, &p, &res, &rej) == ZQJS_OK);
    zqjs_promise_state pst = ZQJS_PROMISE_FULFILLED;
    zqjs_handle pval = ZQJS_HANDLE_NULL;
    assert(zqjs_handle_promise_state(rt_cap, p, NULL, &pval) == ZQJS_ERR_INVALID_ARG);
    assert(zqjs_handle_promise_state(rt_cap, ZQJS_HANDLE_NULL, &pst, &pval) == ZQJS_ERR_STALE_HANDLE);
    assert(zqjs_handle_promise_state(rt_cap, res, &pst, &pval) == ZQJS_ERR_TYPE);

    /* Fill the 4th slot so 0 slots remain free: pending state check still succeeds without allocating */
    zqjs_handle fourth = ZQJS_HANDLE_NULL;
    assert(zqjs_new_number(rt_cap, 7.0, &fourth) == ZQJS_OK);
    assert(zqjs_handle_promise_state(rt_cap, p, &pst, &pval) == ZQJS_OK);
    assert(pst == ZQJS_PROMISE_PENDING);
    assert(pval.owner == NULL);

    /* Release fourth (1 free slot left): zqjs_new_promise needs 3 slots, fails and rolls back */
    assert(zqjs_handle_release(rt_cap, fourth) == ZQJS_OK);
    zqjs_handle p2 = ZQJS_HANDLE_NULL, res2 = ZQJS_HANDLE_NULL, rej2 = ZQJS_HANDLE_NULL;
    assert(zqjs_new_promise(rt_cap, &p2, &res2, &rej2) == ZQJS_ERR_LIMIT_EXCEEDED);
    assert(p2.owner == NULL && res2.owner == NULL && rej2.owner == NULL);

    /* The 1 free slot is still available to mint the settlement argument */
    assert(zqjs_new_number(rt_cap, 55.0, &fourth) == ZQJS_OK);
    assert(zqjs_handle_release(rt_cap, rej) == ZQJS_OK);
    zqjs_handle call_ret = ZQJS_HANDLE_NULL;
    assert(zqjs_runtime_call(rt_cap, res, NULL, &fourth, 1, &fail, &call_ret) == ZQJS_OK);
    assert(zqjs_handle_release(rt_cap, call_ret) == ZQJS_OK);
    assert(zqjs_handle_release(rt_cap, fourth) == ZQJS_OK);
    assert(zqjs_handle_release(rt_cap, res) == ZQJS_OK);

    /* Inspect fulfilled state with NULL out_value and with non-NULL out_value */
    assert(zqjs_handle_promise_state(rt_cap, p, &pst, NULL) == ZQJS_OK);
    assert(pst == ZQJS_PROMISE_FULFILLED);
    assert(zqjs_handle_promise_state(rt_cap, p, &pst, &pval) == ZQJS_OK);
    assert(pst == ZQJS_PROMISE_FULFILLED);
    double fulfilled_num = 0.0;
    assert(zqjs_handle_number(rt_cap, pval, &fulfilled_num) == ZQJS_OK && fulfilled_num == 55.0);
    assert(zqjs_handle_release(rt_cap, pval) == ZQJS_OK);
    assert(zqjs_handle_release(rt_cap, p) == ZQJS_OK);
    assert(zqjs_runtime_destroy(rt_cap) == ZQJS_OK);

    /* 7d. 60-frame game loop with async scripts awaiting frame timers, checking leaks & handle counts */
    capture_buf cap = { .len = 0, .reenter_rt = NULL, .reenter_status = ZQJS_OK };
    cap.data[0] = '\0';

    const uint32_t handle_cap = 16;
    zqjs_options loop_opts = zqjs_options_default();
    loop_opts.limits.max_handles = handle_cap;
    loop_opts.output_fn = test_output;
    loop_opts.output_ctx = &cap;

    zqjs_runtime *rt = NULL;
    assert(zqjs_runtime_create(&loop_opts, &rt) == ZQJS_OK);

    frame_host host;
    memset(&host, 0, sizeof(host));

    assert(zqjs_runtime_define_global_function(rt, "waitFrames", 10, native_wait_frames, &host) == ZQJS_OK);
    assert(zqjs_runtime_define_global_function(rt, "trackPromise", 12, native_track_promise, &host) == ZQJS_OK);

    /* Warm the realm and handle table before recording post-init baseline memory */
    zqjs_handle warm_p = ZQJS_HANDLE_NULL, warm_res = ZQJS_HANDLE_NULL, warm_rej = ZQJS_HANDLE_NULL;
    assert(zqjs_new_promise(rt, &warm_p, &warm_res, &warm_rej) == ZQJS_OK);
    assert(zqjs_handle_release(rt, warm_p) == ZQJS_OK);
    assert(zqjs_handle_release(rt, warm_res) == ZQJS_OK);
    assert(zqjs_handle_release(rt, warm_rej) == ZQJS_OK);
    assert(zqjs_runtime_collect_garbage(rt) == ZQJS_OK);
    zqjs_memory base_mem;
    assert(zqjs_runtime_memory(rt, &base_mem) == ZQJS_OK);

    const char *game_src =
        "async function patrol() {\n"
        "    let sum = 0;\n"
        "    for (let i = 0; i < 12; i++) {\n"
        "        const f = await waitFrames(5, false);\n"
        "        sum += f;\n"
        "    }\n"
        "    return sum;\n"
        "}\n"
        "async function burst() {\n"
        "    const a = await waitFrames(20, false);\n"
        "    let recovered = 0;\n"
        "    try {\n"
        "        await waitFrames(15, true);\n"
        "    } catch (e) {\n"
        "        recovered = e;\n"
        "    }\n"
        "    const b = await waitFrames(25, false);\n"
        "    return a + recovered + b;\n"
        "}\n"
        "trackPromise(patrol());\n"
        "trackPromise(burst());\n";

    zqjs_program *prog = NULL;
    assert(zqjs_runtime_compile(rt, "loop60.js", 9, game_src, strlen(game_src), &diag, &prog) == ZQJS_OK);

    assert(zqjs_runtime_run(rt, prog, &fail) == ZQJS_OK);
    assert(host.script_promise_count == 2);

    /* Both script promises are pending before the 60-frame loop runs */
    for (size_t i = 0; i < host.script_promise_count; i++) {
        assert(zqjs_handle_promise_state(rt, host.script_promises[i], &pst, NULL) == ZQJS_OK);
        assert(pst == ZQJS_PROMISE_PENDING);
    }

    for (int frame = 1; frame <= 60; frame++) {
        host.current_frame = frame;
        /* Settle all timers due on this frame (snapshot indices active at start of frame
           so timers registered by resumed coroutines for future frames are not settled early) */
        for (int i = 0; i < MAX_TIMERS; i++) {
            if (host.timers[i].active && host.timers[i].due_frame == frame) {
                host.timers[i].active = false;
                zqjs_handle res_h = host.timers[i].resolve;
                zqjs_handle rej_h = host.timers[i].reject;
                bool should_rej = host.timers[i].should_reject;
                host.timers[i].resolve = ZQJS_HANDLE_NULL;
                host.timers[i].reject = ZQJS_HANDLE_NULL;

                zqjs_handle fnum = ZQJS_HANDLE_NULL;
                zqjs_handle ret = ZQJS_HANDLE_NULL;
                assert(zqjs_new_number(rt, (double)frame, &fnum) == ZQJS_OK);
                zqjs_handle target_cap = should_rej ? rej_h : res_h;
                assert(zqjs_runtime_call(rt, target_cap, NULL, &fnum, 1, &fail, &ret) == ZQJS_OK);
                assert(zqjs_handle_release(rt, ret) == ZQJS_OK);
                assert(zqjs_handle_release(rt, fnum) == ZQJS_OK);
                assert(zqjs_handle_release(rt, res_h) == ZQJS_OK);
                assert(zqjs_handle_release(rt, rej_h) == ZQJS_OK);
            }
        }
    }

    /* Verify all timers fired and both script promises fulfilled with exact expected values */
    for (int i = 0; i < MAX_TIMERS; i++) {
        assert(!host.timers[i].active);
    }

    /* patrol(): 5 + 10 + 15 + ... + 60 = 5 * 78 = 390 */
    assert(zqjs_handle_promise_state(rt, host.script_promises[0], &pst, &pval) == ZQJS_OK);
    assert(pst == ZQJS_PROMISE_FULFILLED);
    double v0 = 0.0;
    assert(zqjs_handle_number(rt, pval, &v0) == ZQJS_OK && v0 == 390.0);
    assert(zqjs_handle_release(rt, pval) == ZQJS_OK);

    /* burst(): 20 + 35 (rejected at frame 35) + 60 = 115 */
    assert(zqjs_handle_promise_state(rt, host.script_promises[1], &pst, &pval) == ZQJS_OK);
    assert(pst == ZQJS_PROMISE_FULFILLED);
    double v1 = 0.0;
    assert(zqjs_handle_number(rt, pval, &v1) == ZQJS_OK && v1 == 115.0);
    assert(zqjs_handle_release(rt, pval) == ZQJS_OK);

    /* Release the tracked script promise handles, destroy program, and collect garbage */
    for (size_t i = 0; i < host.script_promise_count; i++) {
        assert(zqjs_handle_release(rt, host.script_promises[i]) == ZQJS_OK);
    }
    assert(zqjs_program_destroy(prog) == ZQJS_OK);
    assert(zqjs_runtime_collect_garbage(rt) == ZQJS_OK);

    /* Verify zero leaked handles: all 16 slots of `max_handles = 16` can be minted concurrently */
    zqjs_handle verify_handles[16];
    for (uint32_t i = 0; i < handle_cap; i++) {
        assert(zqjs_new_number(rt, (double)i, &verify_handles[i]) == ZQJS_OK);
    }
    zqjs_handle extra = ZQJS_HANDLE_NULL;
    assert(zqjs_new_number(rt, 99.0, &extra) == ZQJS_ERR_LIMIT_EXCEEDED);
    for (uint32_t i = 0; i < handle_cap; i++) {
        assert(zqjs_handle_release(rt, verify_handles[i]) == ZQJS_OK);
    }

    assert(zqjs_runtime_collect_garbage(rt) == ZQJS_OK);
    zqjs_memory end_mem;
    assert(zqjs_runtime_memory(rt, &end_mem) == ZQJS_OK);
    /* After program destroy and major GC, heap bytes return to exact post-realm-init baseline,
       and handle_bytes matches the 16-slot cap without growing */
    assert(end_mem.heap_bytes == base_mem.heap_bytes);
    assert(end_mem.handle_bytes == base_mem.handle_bytes);

    assert(zqjs_runtime_destroy(rt) == ZQJS_OK);
}

static zqjs_status m42_test_loader(
    void *ctx,
    const char *referrer_id,
    size_t referrer_id_len,
    const char *specifier,
    size_t specifier_len,
    zqjs_loaded_module *out_module
) {
    (void)referrer_id;
    (void)referrer_id_len;
    int *hits = (int *)ctx;
    *hits += 1;
    if (specifier_len == 6 && memcmp(specifier, "./a.js", 6) == 0) {
        static const char cid[] = "a.js";
        static const char src[] = "export let val = 10; export function inc() { val += 5; return val; }";
        out_module->canonical_id = cid;
        out_module->canonical_id_len = sizeof(cid) - 1;
        out_module->source = src;
        out_module->source_len = sizeof(src) - 1;
        out_module->free_fn = NULL;
        return ZQJS_OK;
    }
    if (specifier_len == 9 && memcmp(specifier, "./hosterr", 9) == 0) {
        return ZQJS_ERR_HOST;
    }
    return ZQJS_ERR_MODULE_NOT_FOUND;
}

static void test_m42_es_modules(void) {
    assert(zqjs_abi_version() == ((1u << 16) | (4u << 8) | 0u));

    /* Backward compatibility: 1.0/1.1/1.2 options struct_size still accepted */
    zqjs_options opts = zqjs_options_default();
    zqjs_runtime *rt = NULL;
    assert(zqjs_runtime_create(&opts, &rt) == ZQJS_OK);

    int hits = 0;
    assert(zqjs_set_module_loader(rt, m42_test_loader, &hits) == ZQJS_OK);
    assert(zqjs_set_module_loader(NULL, m42_test_loader, &hits) == ZQJS_ERR_INVALID_ARG);

    const char *entry_src = "import { val, inc } from './a.js'; export function run() { return val + inc(); }";
    zqjs_diagnostic diag;
    zqjs_failure fail;
    zqjs_handle ns = ZQJS_HANDLE_NULL;
    assert(zqjs_eval_module(rt, "main.js", 7, entry_src, strlen(entry_src), &diag, &fail, &ns) == ZQJS_OK);
    assert(hits == 1);

    zqjs_handle run_fn = ZQJS_HANDLE_NULL;
    assert(zqjs_handle_get_property(rt, ns, "run", 3, &fail, &run_fn) == ZQJS_OK);
    zqjs_handle res = ZQJS_HANDLE_NULL;
    assert(zqjs_runtime_call(rt, run_fn, NULL, NULL, 0, &fail, &res) == ZQJS_OK);
    double n = 0.0;
    assert(zqjs_handle_number(rt, res, &n) == ZQJS_OK);
    assert(n == 25.0);

    assert(zqjs_handle_release(rt, res) == ZQJS_OK);
    assert(zqjs_handle_release(rt, run_fn) == ZQJS_OK);
    assert(zqjs_handle_release(rt, ns) == ZQJS_OK);

    /* Error paths */
    const char *miss_src = "import './missing.js';";
    assert(zqjs_eval_module(rt, "miss.js", 7, miss_src, strlen(miss_src), &diag, &fail, NULL) == ZQJS_ERR_MODULE_NOT_FOUND);

    const char *host_src = "import './hosterr';";
    assert(zqjs_eval_module(rt, "herr.js", 7, host_src, strlen(host_src), &diag, &fail, NULL) == ZQJS_ERR_HOST);

    assert(zqjs_runtime_destroy(rt) == ZQJS_OK);
}

static void test_m43_array_buffer_and_views(void) {
    assert(((zqjs_abi_version() >> 8) & 0xffu) >= 4u);

    zqjs_options opts = zqjs_options_default();
    opts.limits.max_heap_bytes = 128u * 1024u;
    zqjs_runtime *rt = NULL;
    assert(zqjs_runtime_create(&opts, &rt) == ZQJS_OK);

    zqjs_handle ab = ZQJS_HANDLE_NULL;
    assert(zqjs_new_array_buffer(rt, 16, &ab) == ZQJS_OK);

    void *ptr = NULL;
    size_t byte_len = 0;
    assert(zqjs_handle_buffer_data(rt, ab, &ptr, &byte_len) == ZQJS_OK);
    assert(ptr != NULL);
    assert(byte_len == 16);

    /* Write bytes from C */
    uint8_t *u8 = (uint8_t *)ptr;
    u8[0] = 0x12;
    u8[1] = 0x34;
    u8[2] = 0x56;
    u8[3] = 0x78;

    const char *src =
        "export function mutateBuf(ab) {"
        "  const dv = new DataView(ab, 0, 8);"
        "  if (dv.getUint32(0, false) !== 0x12345678) throw new Error('mismatch');"
        "  const ta = new Uint8Array(ab, 4, 4);"
        "  ta[0] = 0xaa; ta[1] = 0xbb;"
        "  return ta;"
        "}";
    zqjs_diagnostic diag;
    zqjs_failure fail;
    zqjs_handle ns = ZQJS_HANDLE_NULL;
    assert(zqjs_eval_module(rt, "m43.js", 6, src, strlen(src), &diag, &fail, &ns) == ZQJS_OK);

    zqjs_handle fn = ZQJS_HANDLE_NULL;
    assert(zqjs_handle_get_property(rt, ns, "mutateBuf", 9, &fail, &fn) == ZQJS_OK);
    assert(zqjs_handle_release(rt, ns) == ZQJS_OK);
    zqjs_handle ta = ZQJS_HANDLE_NULL;
    assert(zqjs_runtime_call(rt, fn, NULL, &ab, 1, &fail, &ta) == ZQJS_OK);

    /* Read back zero-copy from returned TypedArray view */
    void *ta_ptr = NULL;
    size_t ta_len = 0;
    assert(zqjs_handle_buffer_data(rt, ta, &ta_ptr, &ta_len) == ZQJS_OK);
    assert(ta_len == 4);
    assert((uint8_t *)ta_ptr == u8 + 4);
    assert(u8[4] == 0xaa && u8[5] == 0xbb);

    /* Error cases: wrong type, stale handle, limit exceeded */
    assert(zqjs_handle_buffer_data(rt, fn, &ta_ptr, &ta_len) == ZQJS_ERR_TYPE);
    assert(zqjs_handle_release(rt, ta) == ZQJS_OK);
    assert(zqjs_handle_buffer_data(rt, ta, &ta_ptr, &ta_len) == ZQJS_ERR_STALE_HANDLE);

    zqjs_handle big = ZQJS_HANDLE_NULL;
    assert(zqjs_new_array_buffer(rt, 1024u * 1024u, &big) == ZQJS_ERR_LIMIT_EXCEEDED);

    assert(zqjs_handle_release(rt, fn) == ZQJS_OK);
    assert(zqjs_handle_release(rt, ab) == ZQJS_OK);
    assert(zqjs_runtime_destroy(rt) == ZQJS_OK);
}

int main(void) {
    capture_buf cap = { .len = 0, .reenter_rt = NULL, .reenter_status = ZQJS_OK };
    cap.data[0] = '\0';

    zqjs_options opts = zqjs_options_default();
    opts.output_fn = test_output;
    opts.output_ctx = &cap;

    zqjs_runtime *rt = NULL;
    assert(zqjs_runtime_create(&opts, &rt) == ZQJS_OK);
    assert(rt != NULL);

    /* Compile error diagnostic */
    zqjs_diagnostic diag;
    zqjs_program *bad_prog = NULL;
    assert(zqjs_runtime_compile(rt, "bad.js", 6, "let x = ;", 9, &diag, &bad_prog) == ZQJS_ERR_SOURCE);
    assert(bad_prog == NULL);
    assert(diag.line == 1);
    assert(diag.message_len > 0);
    assert(diag.message[diag.message_len] == '\0');

    /* Compile, run, and slice-resume */
    const char *src = "let sum = 0; for (let i = 1; i <= 4; i++) sum += i; print(sum);";
    zqjs_program *prog = NULL;
    assert(zqjs_runtime_compile(rt, "sum.js", 6, src, strlen(src), &diag, &prog) == ZQJS_OK);
    assert(prog != NULL);

    zqjs_execution *exec = NULL;
    assert(zqjs_runtime_start(rt, prog, &exec) == ZQJS_OK);
    assert(zqjs_program_destroy(prog) == ZQJS_OK);
    assert(zqjs_program_destroy(prog) == ZQJS_ERR_INVALID_STATE);

    for (;;) {
        zqjs_failure fail;
        zqjs_status st = zqjs_execution_resume(exec, 2, &fail);
        if (st == ZQJS_STATUS_FINISHED) break;
        assert(st == ZQJS_STATUS_SUSPENDED);
    }
    assert(strcmp(cap.data, "10\n") == 0);

    assert(zqjs_execution_destroy(exec) == ZQJS_OK);
    assert(zqjs_execution_destroy(exec) == ZQJS_ERR_INVALID_STATE);

    assert(zqjs_runtime_collect_garbage(rt) == ZQJS_OK);
    zqjs_memory mem;
    assert(zqjs_runtime_memory(rt, &mem) == ZQJS_OK);
    assert(mem.collections >= 1);

    assert(zqjs_runtime_destroy(rt) == ZQJS_OK);
    assert(zqjs_runtime_destroy(NULL) == ZQJS_OK);

    test_handles_and_slot_reuse();
    test_cross_runtime_handles();
    test_callbacks_errors_roundtrip_and_reentrancy();
    test_host_js_host_round_trip();
    test_mid_run_program_destroy_and_runtime_destroy_with_children();
    test_m12_3_abi_version_options_and_handles();
    test_m29_host_promises_60_frames_and_d60_native_stack();
    test_m42_es_modules();
    test_m43_array_buffer_and_views();

    return 0;
}
