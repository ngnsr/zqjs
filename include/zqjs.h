#ifndef ZQJS_H
#define ZQJS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * C ABI version encoded as `(major << 16) | (minor << 8) | patch`.
 * - Major bumps only on breaking layout, signature, or semantic changes.
 * - Minor bumps on backward-compatible additions (new functions or trailing
 *   fields on `zqjs_options` gated by `struct_size`).
 * Callers can check `(zqjs_abi_version() >> 16) == (ZQJS_ABI_VERSION >> 16)`.
 */
#define ZQJS_ABI_MAJOR 1u
#define ZQJS_ABI_MINOR 1u
#define ZQJS_ABI_PATCH 0u
#define ZQJS_ABI_VERSION ((ZQJS_ABI_MAJOR << 16) | (ZQJS_ABI_MINOR << 8) | ZQJS_ABI_PATCH)

typedef struct zqjs_runtime zqjs_runtime;
typedef struct zqjs_program zqjs_program;
typedef struct zqjs_execution zqjs_execution;

typedef struct zqjs_handle {
    void *owner;
    uint32_t slot;
    uint64_t generation;
} zqjs_handle;

#define ZQJS_HANDLE_NULL ((zqjs_handle){ NULL, 0u, 0ull })

typedef enum zqjs_status {
    ZQJS_OK = 0,
    ZQJS_STATUS_SUSPENDED = 1,
    ZQJS_STATUS_FINISHED = 2,
    ZQJS_ERR_SOURCE = -1,
    ZQJS_ERR_BUSY = -2,
    ZQJS_ERR_THROWN = -3,
    ZQJS_ERR_HOST = -4,
    ZQJS_ERR_LIMIT_EXCEEDED = -5,
    ZQJS_ERR_UNSUPPORTED = -6,
    ZQJS_ERR_OUT_OF_MEMORY = -7,
    ZQJS_ERR_OUTPUT_FAILED = -8,
    ZQJS_ERR_NAME_TAKEN = -9,
    ZQJS_ERR_INTERNAL = -10,
    ZQJS_ERR_INVALID_ARG = -11,
    ZQJS_ERR_INVALID_STATE = -12,
    ZQJS_ERR_STALE_HANDLE = -13,
    ZQJS_ERR_FOREIGN_HANDLE = -14,
    ZQJS_ERR_TYPE = -15
} zqjs_status;

typedef enum zqjs_limit {
    ZQJS_LIMIT_NONE = -1,
    ZQJS_LIMIT_SOURCE_BYTES = 0,
    ZQJS_LIMIT_NESTING_DEPTH = 1,
    ZQJS_LIMIT_STEPS = 2,
    ZQJS_LIMIT_HEAP_BYTES = 3,
    ZQJS_LIMIT_STRING_LENGTH = 4,
    ZQJS_LIMIT_CODE_BYTES = 5,
    ZQJS_LIMIT_CONSTANTS = 6,
    ZQJS_LIMIT_CALL_DEPTH = 7,
    ZQJS_LIMIT_STACK_SLOTS = 8,
    ZQJS_LIMIT_INTERPRETER_DEPTH = 9,
    ZQJS_LIMIT_CONVERSION_DEPTH = 10,
    ZQJS_LIMIT_HANDLES = 11
} zqjs_limit;

typedef enum zqjs_failure_kind {
    ZQJS_FAILURE_THROWN = 0,
    ZQJS_FAILURE_HOST = 1,
    ZQJS_FAILURE_LIMIT = 2,
    ZQJS_FAILURE_UNSUPPORTED = 3,
    ZQJS_FAILURE_OUT_OF_MEMORY = 4,
    ZQJS_FAILURE_OUTPUT = 5,
    ZQJS_FAILURE_INTERNAL = 6
} zqjs_failure_kind;

typedef enum zqjs_error_name {
    ZQJS_ERROR_TYPE = 0,
    ZQJS_ERROR_RANGE = 1,
    ZQJS_ERROR_REFERENCE = 2
} zqjs_error_name;

typedef enum zqjs_handle_kind {
    ZQJS_HANDLE_UNDEFINED = 0,
    ZQJS_HANDLE_NULL_VAL = 1,
    ZQJS_HANDLE_BOOLEAN = 2,
    ZQJS_HANDLE_NUMBER = 3,
    ZQJS_HANDLE_STRING = 4,
    ZQJS_HANDLE_FUNCTION = 5,
    ZQJS_HANDLE_OBJECT = 6,
    ZQJS_HANDLE_ARRAY = 7
} zqjs_handle_kind;

typedef struct zqjs_limits {
    uint32_t max_source_bytes;
    uint16_t max_nesting_depth;
    uint64_t max_steps;
    size_t max_heap_bytes;
    size_t nursery_bytes;
    size_t max_string_length;
    uint32_t max_code_bytes;
    uint32_t max_constants;
    uint32_t max_call_depth;
    uint32_t max_stack_slots;
    uint32_t max_interpreter_depth;
    uint32_t max_conversion_depth;
    uint32_t max_handles;
} zqjs_limits;

typedef bool (*zqjs_output_fn)(void *ctx, const char *bytes, size_t len);
typedef uint64_t (*zqjs_clock_fn)(void *ctx);

typedef struct zqjs_options {
    /**
     * Must be initialized to `sizeof(zqjs_options)` (e.g. via `zqjs_options_default()`).
     * - Smaller structs (`>= offsetof(zqjs_options, clock_ctx) + sizeof(void *)`) are
     *   accepted for backward compatibility; omitted trailing fields (e.g. `random_seed`)
     *   use their documented defaults.
     * - Zero, truncated, or larger structs (`> sizeof(zqjs_options)`) are rejected with
     *   `ZQJS_ERR_INVALID_ARG`.
     */
    uint32_t struct_size;
    uint32_t reserved;
    zqjs_limits limits;
    zqjs_output_fn output_fn;
    void *output_ctx;
    zqjs_clock_fn clock_fn;
    void *clock_ctx;
    /** Deterministic PRNG seed for `Math.random()` (not cryptographically secure). */
    uint64_t random_seed;
} zqjs_options;

typedef struct zqjs_diagnostic {
    char message[257];
    size_t message_len;
    bool truncated;
    uint32_t line;
    uint32_t column;
    uint32_t start;
    uint32_t end;
} zqjs_diagnostic;

typedef struct zqjs_failure {
    zqjs_failure_kind kind;
    zqjs_limit limit;
    char message[257];
    size_t message_len;
    bool truncated;
} zqjs_failure;

typedef struct zqjs_memory {
    size_t bytes;
    size_t peak;
    size_t heap_bytes;
    size_t handle_bytes;
    uint64_t collections;
    uint64_t minor_collections;
    uint64_t major_collections;
    uint64_t last_gc_pause_ns;
    uint64_t max_gc_pause_ns;
} zqjs_memory;

typedef struct zqjs_native_out {
    bool has_result;
    zqjs_handle result;
    const char *host_message;
    size_t host_message_len;
} zqjs_native_out;

typedef zqjs_status (*zqjs_native_fn)(
    zqjs_runtime *rt,
    void *ctx,
    const zqjs_handle *opt_this,
    const zqjs_handle *args,
    size_t argc,
    zqjs_native_out *out
);

/* ABI version & defaults */
uint32_t zqjs_abi_version(void);
zqjs_limits zqjs_limits_default(void);
zqjs_options zqjs_options_default(void);

/* Runtime, Program, Execution lifecycle */
zqjs_status zqjs_runtime_create(const zqjs_options *opts, zqjs_runtime **out_rt);
zqjs_status zqjs_runtime_destroy(zqjs_runtime *rt);

zqjs_status zqjs_runtime_compile(
    zqjs_runtime *rt,
    const char *name,
    size_t name_len,
    const char *source,
    size_t source_len,
    zqjs_diagnostic *out_diag,
    zqjs_program **out_prog
);
zqjs_status zqjs_program_destroy(zqjs_program *prog);

zqjs_status zqjs_runtime_run(zqjs_runtime *rt, zqjs_program *prog, zqjs_failure *out_fail);
zqjs_status zqjs_runtime_start(zqjs_runtime *rt, zqjs_program *prog, zqjs_execution **out_exec);
zqjs_status zqjs_execution_resume(zqjs_execution *exec, uint64_t steps, zqjs_failure *out_fail);
zqjs_status zqjs_execution_destroy(zqjs_execution *exec);

zqjs_status zqjs_runtime_collect_garbage(zqjs_runtime *rt);
zqjs_status zqjs_runtime_memory(const zqjs_runtime *rt, zqjs_memory *out_mem);

/* Handles */
zqjs_status zqjs_new_number(zqjs_runtime *rt, double n, zqjs_handle *out_handle);
zqjs_status zqjs_new_boolean(zqjs_runtime *rt, bool b, zqjs_handle *out_handle);
zqjs_status zqjs_new_string_utf16(
    zqjs_runtime *rt,
    const uint16_t *units,
    size_t len,
    zqjs_handle *out_handle
);
zqjs_status zqjs_new_object(zqjs_runtime *rt, zqjs_handle *out_handle);
zqjs_status zqjs_new_array(zqjs_runtime *rt, zqjs_handle *out_handle);
zqjs_status zqjs_runtime_get_global(
    zqjs_runtime *rt,
    const char *name,
    size_t name_len,
    zqjs_failure *out_fail,
    zqjs_handle *out_handle
);
zqjs_status zqjs_handle_get_property(
    zqjs_runtime *rt,
    zqjs_handle obj,
    const char *key,
    size_t key_len,
    zqjs_failure *out_fail,
    zqjs_handle *out_handle
);
zqjs_status zqjs_handle_set_property(
    zqjs_runtime *rt,
    zqjs_handle obj,
    const char *key,
    size_t key_len,
    zqjs_handle val,
    zqjs_failure *out_fail
);
zqjs_status zqjs_handle_get_index(
    zqjs_runtime *rt,
    zqjs_handle obj,
    uint32_t index,
    zqjs_failure *out_fail,
    zqjs_handle *out_handle
);
zqjs_status zqjs_handle_set_index(
    zqjs_runtime *rt,
    zqjs_handle obj,
    uint32_t index,
    zqjs_handle val,
    zqjs_failure *out_fail
);

zqjs_status zqjs_handle_kind_of(const zqjs_runtime *rt, zqjs_handle h, zqjs_handle_kind *out_kind);
zqjs_status zqjs_handle_number(const zqjs_runtime *rt, zqjs_handle h, double *out_n);
zqjs_status zqjs_handle_boolean(const zqjs_runtime *rt, zqjs_handle h, bool *out_b);
zqjs_status zqjs_handle_string_utf16(
    const zqjs_runtime *rt,
    zqjs_handle h,
    uint16_t *buf,
    size_t buf_len,
    size_t *out_full_len
);
zqjs_status zqjs_handle_dup(zqjs_runtime *rt, zqjs_handle h, zqjs_handle *out_handle);
zqjs_status zqjs_handle_release(zqjs_runtime *rt, zqjs_handle h);

/* Native callbacks & JS calls */
zqjs_status zqjs_runtime_define_global_function(
    zqjs_runtime *rt,
    const char *name,
    size_t name_len,
    zqjs_native_fn fn,
    void *ctx
);
zqjs_status zqjs_runtime_throw_js(
    zqjs_runtime *rt,
    zqjs_error_name name,
    const uint16_t *msg,
    size_t msg_len
);
zqjs_status zqjs_runtime_call(
    zqjs_runtime *rt,
    zqjs_handle fn,
    const zqjs_handle *opt_this,
    const zqjs_handle *args,
    size_t argc,
    zqjs_failure *out_fail,
    zqjs_handle *out_result
);

#ifdef __cplusplus
}
#endif

#endif /* ZQJS_H */
