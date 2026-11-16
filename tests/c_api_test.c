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
    assert(zqjs_runtime_destroy(rt) == ZQJS_ERR_INVALID_STATE);
    assert(zqjs_runtime_destroy(NULL) == ZQJS_OK);

    test_handles_and_slot_reuse();
    test_cross_runtime_handles();
    test_callbacks_errors_roundtrip_and_reentrancy();
    test_host_js_host_round_trip();
    test_mid_run_program_destroy_and_runtime_destroy_with_children();

    return 0;
}
