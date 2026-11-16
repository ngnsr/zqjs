/* Standalone C11 embedding example linking against installed libzqjs.a + zqjs.h */

#include "zqjs.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef struct host_state {
    zqjs_handle on_tick;
} host_state;

static bool on_print(void *ctx, const char *bytes, size_t len) {
    (void)ctx;
    return fwrite(bytes, 1, len, stdout) == len;
}

static zqjs_status native_set_tick(
    zqjs_runtime *rt,
    void *raw_ctx,
    const zqjs_handle *opt_this,
    const zqjs_handle *args,
    size_t argc,
    zqjs_native_out *out
) {
    (void)opt_this;
    (void)out;
    host_state *st = (host_state *)raw_ctx;
    if (argc < 1) {
        const uint16_t msg[] = { 'e', 'x', 'p', 'e', 'c', 't', 'e', 'd', ' ', 'f', 'n' };
        zqjs_runtime_throw_js(rt, ZQJS_ERROR_TYPE, msg, 11);
        return ZQJS_ERR_THROWN;
    }
    zqjs_handle duped = ZQJS_HANDLE_NULL;
    zqjs_status err = zqjs_handle_dup(rt, args[0], &duped);
    if (err != ZQJS_OK) return err;

    if (st->on_tick.owner != NULL) {
        zqjs_handle_release(rt, st->on_tick);
    }
    st->on_tick = duped;
    return ZQJS_OK;
}

int main(void) {
    zqjs_options opts = zqjs_options_default();
    opts.limits.max_heap_bytes = 4u * 1024u * 1024u;
    opts.limits.max_steps = 100000ull;
    opts.output_fn = on_print;

    zqjs_runtime *rt = NULL;
    assert(zqjs_runtime_create(&opts, &rt) == ZQJS_OK);

    host_state state = { .on_tick = ZQJS_HANDLE_NULL };
    assert(zqjs_runtime_define_global_function(rt, "onTick", 6, native_set_tick, &state) == ZQJS_OK);

    const char *src =
        "let total = 0;"
        "onTick(function(dt) { total += dt; return total; });";
    zqjs_diagnostic diag;
    zqjs_program *prog = NULL;
    assert(zqjs_runtime_compile(rt, "game.js", 7, src, strlen(src), &diag, &prog) == ZQJS_OK);

    zqjs_failure fail;
    assert(zqjs_runtime_run(rt, prog, &fail) == ZQJS_OK);

    for (int frame = 1; frame <= 3; frame++) {
        zqjs_handle dt = ZQJS_HANDLE_NULL;
        zqjs_handle res = ZQJS_HANDLE_NULL;
        assert(zqjs_new_number(rt, 10.0 * frame, &dt) == ZQJS_OK);
        assert(zqjs_runtime_call(rt, state.on_tick, NULL, &dt, 1, &fail, &res) == ZQJS_OK);

        double val = 0.0;
        assert(zqjs_handle_number(rt, res, &val) == ZQJS_OK);
        printf("frame %d -> total = %.0f\n", frame, val);

        assert(zqjs_handle_release(rt, res) == ZQJS_OK);
        assert(zqjs_handle_release(rt, dt) == ZQJS_OK);
    }

    assert(zqjs_runtime_collect_garbage(rt) == ZQJS_OK);
    zqjs_memory mem;
    assert(zqjs_runtime_memory(rt, &mem) == ZQJS_OK);
    printf("memory: %zu B (collections: %llu)\n", mem.bytes, (unsigned long long)mem.collections);

    assert(zqjs_handle_release(rt, state.on_tick) == ZQJS_OK);
    assert(zqjs_program_destroy(prog) == ZQJS_OK);
    assert(zqjs_runtime_destroy(rt) == ZQJS_OK);
    return 0;
}
