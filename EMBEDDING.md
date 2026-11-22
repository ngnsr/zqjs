# Embedding ZQJS in Zig

ZQJS is designed from the ground up to be embedded in host applications (game loops, simulation engines, command-line tools). The embedding API provides host control over execution time, resource limits, and memory, without exposing the virtual machine's internal structures.

To embed ZQJS, your Zig build only requires the `zqjs` module. All engine internals (`Vm`, `Proto`, `Heap`, GC cards and bitmaps) stay private and inaccessible.

---

## Architecture & Concepts

The embedding API is built around four **opaque handles**:

```
Runtime                       owns heap, realm, handle table, root list, and everything below
 ├── Program A                compiled bytecode and constants; reusable GC root
 ├── Program B                compiled, never run; safely reclaimed on destroy
 ├── Execution 1 (of A)       isolated VM state (frames, pc, stacks, locals)
 ├── Execution 2 (of A)       second run of A with independent local variables
 └── Handle tokens            GC-safe references to JS values crossing the host/JS boundary
```

### 1. Ownership & Lifecycle (E1)
- **Nothing outlives its runtime:** `Runtime.destroy(rt)` immediately tears down all active programs, executions, host native registrations, and handle tables/pools, releases all registered GC roots, and frees the heap and realm. Any host pointers held after `destroy` are invalid.
- **Reference-counted Programs:** A compiled `*Program` has an internal reference count: one for the host's handle, plus one for every active `*Execution` started from it.
  - Calling `Program.destroy(prog)` invalidates the host handle immediately.
  - Any active executions of that program continue running unaffected, retaining the bytecode and string constants as GC roots.
  - The program's constants and bytecode are freed once the last execution is destroyed, or when the runtime is destroyed, whichever comes first.
- **Early Execution Destruction:** Calling `Execution.destroy(ex)` drops its VM stacks and unregisters its GC roots immediately, regardless of whether it is running, suspended, or faulted.
- **Use after destroy is a host bug.** In safe builds every entry point checks a tag on the object it receives and panics naming the type (`zqjs: Program used after destroy`, `zqjs: Runtime used after destroy`, `zqjs: Execution used after destroy`). This is best effort: freed memory may have been reused, so a missed catch is possible.

### 2. Thread Safety, The Entry Guard, & Re-entrancy Rules (E2, D52)
- A runtime is strictly single-threaded at any instant: calls into a runtime or any object it owns must never overlap across threads.
- Every API call validates an internal atomic entry guard and owner thread id.
- **At depth 0 (idle):** any public API call claims the guard as a host entry.
- **Inside an active `NativeFn` callback (depth ≥ 1 on the owner thread):** the engine holds a callback-scoped `NativeRecord` capability on the execution context:
  - **Sanctioned re-entrant calls (succeed):** `rt.call`, `rt.newNumber`, `rt.newBoolean`, `rt.newStringUtf16`, `rt.newObject`, `rt.newArray`, `rt.newPromise`, `rt.promiseState`, `rt.getGlobal`, `rt.getProperty`, `rt.setProperty`, `rt.getIndex`, `rt.setIndex`, `rt.throwJs`, `Handle` operations (`kind`, `number`, `boolean`, `string`, `dup`, `release`), `rt.collectGarbage`, and `rt.memory`.
  - **Top-level compilation/execution calls (return `error.Busy`):** `rt.compile`, `rt.start`, and `rt.run` return `error.Busy` without disturbing the active execution.
  - **Unsanctioned host re-entry (panics):** calling `Execution.resume`, `Execution.destroy`, `rt.defineGlobalFunction`, `Program.destroy`, or `rt.destroy` from inside a callback, re-entering from an output writer's `drain` (even during a nested `print` inside `rt.call`), or calling from another thread immediately panics:
    ```
    zqjs: Runtime entered while another call into it is running
    ```
- Runtimes are fully independent: separate runtimes may run concurrently on different threads without locks.

### 3. Compilation & Realm Persistence: Compile Once, Run Many (E3)
- Scripts are compiled with `rt.compile(name, source, &diag)`. Compilation parses, resolves scopes, compiles to bytecode, and verifies bytecode integrity.
- On syntax, scoping, or source limit errors, `compile` returns `error.Source` and populates `Diagnostic` with the message, line, and column. The runtime heap is automatically rolled back to its pre-compilation state.
- A compiled `*Program` can be started any number of times via `rt.start(prog)`. Each start receives a fresh top-level scope and fresh local variables.
- All executions and `rt.call` invocations on a runtime share its JavaScript realm: prototype modifications and host functions registered via `rt.defineGlobalFunction` persist across runs and are visible to all programs on that runtime.

### 4. Cooperative Multitasking, Slice Overshoot, & Cumulative Step Budgets (E4, E5, D51)
ZQJS separates step scheduling into two distinct concepts:

- **The Slice (`steps` in `resume`):** A cooperative hint for when the host regains control. When the slice expires at a VM instruction boundary with the script unfinished, `resume` returns `.suspended`. The execution pauses safely with zero loss of state and can be resumed in the next frame.
- **The Cap (`limits.max_steps`):** The hard stop — the cumulative total instruction limit across all resumes (and all nested `rt.call` executions) for an execution chain. It prevents runaway or infinite loops.

#### Exact Cap, Slice Overshoot, and Latched Budget Semantics
- Each VM instruction increments the chain's live step counter (`rt.step()`).
- **Slice expires:** if the slice budget runs out before `max_steps`, `resume` returns `Status.suspended`.
- **Tie:** if the slice and `max_steps` end on the exact same instruction with the script unfinished, `resume` returns `Status.suspended`. The *next* instruction attempt fails with `error.LimitExceeded` (`Limit.steps`).
- **Completion at cap:** if a script finishes (including its `halt` opcode) at or before `max_steps`, it completes with `Status.finished`, never an error.
- **Budget 0:** calling `ex.@"resume"(0, null)` runs zero instructions and returns `.suspended` (or `.finished` if already done).
- **Slice overshoot across native callbacks:** a synchronous Zig `NativeFn` callback cannot suspend mid-stack. If an instruction invokes a host native that calls back into JS via `rt.call`, the nested chain runs to completion and may **overshoot the `resume(steps)` slice**; the host regains control as soon as the native chain finishes and the outer VM reaches its next step boundary.
- **Latched budget exhaustion:** `limits.max_steps` is never exceeded. If any nested VM in a callback chain hits `max_steps`, `LimitExceeded(steps)` **latches** in the execution context: no further instructions can execute in the chain, and even if a `NativeFn` catches `error.LimitExceeded` from `rt.call` and returns normally (or returns `HostError`/`Thrown`), the outer execution faults at the native boundary with `error.LimitExceeded` (`Limit.steps`).
- **Fault persistence:** once an execution faults, further `resume` calls immediately return the cached error and `Failure`. Other executions on the same runtime remain unaffected.

### 5. GC-Safe Handles (`Handle`, D50, D54)
Any JavaScript value held by the host across an allocation, garbage collection, or execution step is referenced through a value `zqjs.Handle`:

- **Generation-Checked Reusable Slots & Rooting:** A `Handle` is a small value token (`owner`, `slot`, `generation`) referencing an owned slot in the runtime's reusable handle table. Every live slot (`live == true`) is a GC root: the collector traces it during both minor and major collections.
- **Creating & Reading Handles:**
  - `rt.newNumber(f64)`, `rt.newBoolean(bool)`, and `rt.newStringUtf16([]const u16)` mint a new handle owned by the caller.
  - `h.kind()` returns `HandleKind` (`.undefined`, `.null`, `.boolean`, `.number`, `.string`, `.symbol`, `.function`, `.object`, `.array`, `.bigint`).
  - `h.number()` (`?f64`) and `h.boolean()` (`?bool`) copy primitive values out without allocating (`null` if wrong kind).
  - `h.string(buf: []u16)` (`?usize`) returns `null` if `h` is not a string; otherwise it copies `min(len, buf.len)` UTF-16 code units into `buf` **without allocating** and returns the string's **full UTF-16 length** (so truncation is visible whenever `full_len > buf.len`).
- **`dup` and `release`:**
  - `try h.dup()` allocates an independent slot holding the same `Value` and returns a new `Handle` with that slot's index and generation.
  - `h.release()` validates `h`, marks its slot dead (`live = false`), increments its `u64` generation (`generation += 1`), and pushes the slot onto the runtime's free list for zero-allocation reuse. If a slot's generation reaches `std.math.maxInt(u64)`, it is permanently retired rather than returned to the free list so generations never wrap around.
- **Stale/Foreign Handle Detection, Concurrent `Limits.max_handles`, & `Memory` Accounting:**
  - Every handle operation validates `owner`, slot bounds, `live`, and `generation`. Using a handle after `release()` — even after its old slot has been reused by a newer handle — deterministically panics with `"zqjs: Handle used after release"`. Passing a handle minted by one runtime into another live runtime deterministically panics with `"zqjs: Handle from another Runtime"`.
  - `Limits.max_handles` bounds the **maximum slot capacity / concurrent handle capacity** of the handle table, not cumulative lifetime handle creations. Freed slots on the free list are reused on subsequent `mint`/`dup`/callback calls without growing the table; exceeding `max_handles` concurrent handles returns `error.LimitExceeded` (`Limit.handles`) and leaves the runtime usable.
  - `rt.memory()` reports separated metrics (`heap_bytes` for the GC-managed JS heap, `handle_bytes` for actual allocated handle-table capacity, `bytes` = `heap_bytes + handle_bytes`, `peak`), collection counts (`collections`, `minor_collections`, `major_collections`), and — when an optional monotonic nanosecond `Options.clock` callback is supplied — GC pause telemetry (`last_gc_pause_ns`, `max_gc_pause_ns`).

### 6. Host Natives & Callback Handle Ownership (`defineGlobalFunction`, D53)
Host functions are registered on the realm with `rt.defineGlobalFunction(name, native_fn, ctx)`:
- **Duplicate rejection:** registering a name that already exists — including implemented built-ins (`print`, `Object`, `Array`, `undefined`, `NaN`, `Infinity`), node-known built-ins (`Math`, `JSON`, `eval`, etc.), or a previously registered host function — returns `error.NameTaken` and leaves the realm unchanged.
- **`ctx` lifetime:** `ctx: ?*anyopaque` is borrowed by the runtime until `Runtime.destroy`; ZQJS never frees or dereferences it.
- **`this` binding (D41):** in a method call on an object (`obj.fn()`), `this` is a temporary `.object` handle; in a plain call (`fn()`) or a call on a primitive receiver, `this` is `null`.
- **VM-only:** host natives execute on the bytecode VM (the standalone tree-walking oracle reports `Unsupported(builtin)` if a script calls a host native).

#### Handle Ownership Across `NativeFn` and `NativeOut.result`
Every handle crossing a `NativeFn` callback boundary falls into one of three explicit ownership categories:

| Category | Owner | Lifetime & Rule |
|---|---|---|
| **1. Borrowed temporary handles (`this`, `args[i]`)** | Engine (`NativeRecord`) | Valid **only** during the `NativeFn` call; their slots are automatically released and recycled by the engine at callback teardown on every outcome. To keep one after the callback returns, the host **must** call `try args[i].dup()`. Assigning `this` or `args[i]` directly to `out.result` is also permitted (copied before teardown without double-release). |
| **2. Transferred result handle (`out.result`)** | Moved to Engine | Assigning a `Handle` to `out.result` **transfers ownership** of that handle to the engine. At teardown, the engine copies its `Value` into the caller's operand slot first and then releases and recycles its slot on **every** outcome (success, `Thrown`, `HostError`, `LimitExceeded`, `OutOfMemory`, `Internal`), preserving the release-order invariant. Fresh handles from `rt.new*` or `rt.call` may be assigned directly. |
| **3. Host-owned retained handles** | Host | Remain owned by the host until explicitly `release()`d. To return a retained handle `H` as `out.result` while keeping `H` valid for later use, the callback **must** assign `out.result = try H.dup()`. Assigning `H` directly moves `H` to the engine and releases its slot at teardown (any later use of `H` panics with `"zqjs: Handle used after release"`). |

#### Raising Errors from a `NativeFn`
- **JavaScript Exception (`rt.throwJs` + `error.Thrown`):** Call `rt.throwJs(.TypeError | .RangeError | .ReferenceError, utf16_msg)` and return `error.Thrown`. Surfaces as a `Failure.Kind.thrown` failure formatted by E10 rules. Calling `throwJs` without returning `error.Thrown`, or returning `error.Thrown` without a pending exception, is a checked host bug (panics).
- **Host Operation Failure (`out.host_message` + `error.HostError`):** Set `out.host_message = "..."` (valid UTF-8 or sanitized via E10) and return `error.HostError`. Faults the execution with `Failure.Kind.host` and does **not** poison the runtime. Returning `error.HostError` with an empty `host_message` is a checked host bug (panics).
- **Resource & Internal Errors:** `error.LimitExceeded`, `error.Unsupported`, and `error.OutOfMemory` fault the execution and leave the runtime usable; `error.Internal` poisons the runtime (D49).

### 7. Calling JS from the Host (`Runtime.call`, D51)
`rt.call(f, this, args, &failure)` invokes a JS function (or native) `f` with optional object receiver `this` (`null` or non-object leaves `this` unset, D41) and `args`:
- Returns a newly-minted `Handle` owned by the caller (who must `release()` it, or assign it to `out.result` inside a `NativeFn`).
- If `f` is not a function, throws a JS `TypeError: value is not a function` (`error.Thrown`, `Failure.Kind.thrown`).
- **Model B execution:** each JS closure call runs on a fresh nested VM sharing the runtime's heap and realm, registered in the execution context's GC root list for its entire lifetime while any outer VM stays suspended mid-instruction with its roots registered.
- **Top-level vs. nested chains:** calling `rt.call` at guard depth 0 (including while another `Execution` is `.suspended`) runs on a fresh execution context bounded by `limits.max_steps` and `limits.max_call_depth` without disturbing any suspended `Execution`. Calling `rt.call` from inside a `NativeFn` joins the active chain and shares its cumulative step budget and call-depth counter.

### 8. Non-Allocating Errors & Diagnostics (E8, E10)
Script and host errors never panic. Errors are returned as standard Zig errors alongside a non-allocating `Failure` or `Diagnostic` record:

```zig
pub const Failure = struct {
    kind: Kind,                // thrown, host, limit, unsupported, out_of_memory, output, internal
    limit: ?zqjs.Limit,
    text: [256]u8,
    text_len: usize,
    truncated: bool,
    pub fn message(f: *const Failure) []const u8;
};
```

- `text` is guaranteed to be valid UTF-8.
- If a message exceeds 256 bytes, it is truncated strictly at a code point boundary and terminated with `…` (U+2026), setting `truncated = true`.
- UTF-16 surrogate pairs are decoded into valid 4-byte UTF-8 sequences and never split across boundaries; lone surrogates are converted to U+FFFD.

### 9. Internal Errors Poison the Runtime (E7, D49)
A ZQJS bug must never crash the host. A failed VM defensive check, a bytecode verifier rejection after a successful compile, or `error.Internal` from a callback returns `error.Internal` with an `internal` `Failure` instead of panicking.
- The error faults the execution like any other, and **poisons the runtime**: every later call that runs code or mints handles (`compile`, `start`, `run`, `resume`, `call`, `new*`, `promiseState`, `dup`) returns `error.Internal` until `Runtime.destroy`.
- Handle readers/releases, `collectGarbage`, `memory`, and all destroy paths stay usable, so the host can still inspect and clean up.
- The CLI prints `internal error: <reason>` and exits with code 70; the `Failure` text itself stays the fixed `internal error`.

### 10. Host Promises & Async Coroutines (`newPromise`, `promiseState`, M29, D57)
A game or application host lets scripts `await` host events (frame timers, asset loads, network replies) by creating promises on the host side and settling them later from its own loop:

- **Creating a host promise:**
  - **Zig:** `const cap = try rt.newPromise()` returns `PromiseCapability{ .promise, .resolve, .reject }`. All three handles are owned by the caller; inside a `NativeFn`, assign `out.result = cap.promise` to transfer `promise` to the script and keep `cap.resolve` / `cap.reject` until settlement.
  - **C ABI:** `zqjs_new_promise(rt, &promise, &resolve, &reject)` mints three owned handles.
  - If handle creation fails midway (e.g. `Limits.max_handles` or `OutOfMemory`), any already-minted handles are rolled back automatically.
- **Inspecting promise state:**
  - **Zig:** `try rt.promiseState(h)` returns `?PromiseState` (`null` if `h` is not a Promise; `.pending`, `.{ .fulfilled = val_h }`, or `.{ .rejected = reason_h }`). `.pending` never allocates or mints a handle; `.fulfilled` and `.rejected` mint a new owned `Handle` (`h` itself is borrowed).
  - **C ABI:** `zqjs_handle_promise_state(rt, h, &state, &opt_val)` returns `ZQJS_ERR_TYPE` if `h` is not a Promise, sets `state` to `ZQJS_PROMISE_PENDING` / `ZQJS_PROMISE_FULFILLED` / `ZQJS_PROMISE_REJECTED`, and when settled writes a newly-minted handle into `*opt_val` (if `opt_val != NULL`).
- **Rules for settling promises from the host (D57):**
  - **Serialised entry (E2, D52):** calls into a runtime must be serialised — one thread at a time, with no unsanctioned re-entry outside an active `NativeFn` callback.
  - **Settlement via ordinary `call`:** the host settles promises only through ordinary API calls (`rt.call` / `zqjs_runtime_call` on the `resolve` or `reject` capability handle). Calling `resolve` or `reject` on an already-settled promise is a no-op returning `undefined`.
  - **Outermost microtask checkpoint:** settling a promise enqueues reactions and `.await_resume` jobs, and drains the microtask queue at the outermost API checkpoint **before that `call` returns**. Every `async` coroutine and `.then` reaction woken by the settlement runs before control returns to the host.
  - **Limits apply to resumed coroutines:** `max_steps`, `max_heap_bytes`, `max_call_depth`, and `max_native_stack_bytes` apply to all coroutines and callbacks that a settlement resumes.
  - **Fault reporting & pending state:** a fault (`LimitExceeded`, `OutOfMemory`, `HostError`, `Unsupported`, `Internal`) during that checkpoint is reported directly by the host `call` that triggered it. An uncatchable fault consumes the active microtask job, leaves any affected promises pending (as in M18), and preserves the remaining microtask queue for a subsequent checkpoint. Keep the originating `Program` alive while any `async` coroutines started from it remain pending.

---

## Embedding Quickstart

Here is a complete host snippet registering a native function, retaining a JS callback handle with `dup()`, invoking it via `rt.call`, and stepping scripts cooperatively:

```zig
const std = @import("std");
const zqjs = @import("zqjs");

const Bridge = struct {
    hook: ?zqjs.Handle = null,

    fn onScore(
        rt: *zqjs.Runtime,
        raw_ctx: ?*anyopaque,
        _: ?zqjs.Handle,
        args: []const zqjs.Handle,
        out: *zqjs.NativeOut,
    ) zqjs.NativeError!void {
        const self: *Bridge = @ptrCast(@alignCast(raw_ctx.?));
        // args[0] = callback closure, args[1] = points (temporary handles)
        const kept_fn = try args[0].dup();
        if (self.hook) |old| old.release();
        self.hook = kept_fn;

        const multiplier = try rt.newNumber(2);
        defer multiplier.release();

        // JS -> native -> JS round trip; transfer result ownership to `out.result`
        out.result = rt.call(kept_fn, null, &.{ args[1], multiplier }, null) catch |e| return switch (e) {
            error.OutputFailed => error.HostError,
            else => |ne| ne,
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var out_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    defer stdout.interface.flush() catch {};

    const rt = try zqjs.Runtime.create(gpa, .{
        .limits = .{ .max_heap_bytes = 4 * 1024 * 1024, .max_steps = 100_000 },
        .output = &stdout.interface,
    });
    defer rt.destroy();

    var bridge: Bridge = .{};
    defer if (bridge.hook) |h| h.release();

    try rt.defineGlobalFunction("onScore", Bridge.onScore, &bridge);

    const prog = try rt.compile("game.js", "print(onScore(function(pts, m) { return pts * m; }, 21));", null);
    defer prog.destroy();

    const ex = try rt.start(prog);
    defer ex.destroy();

    var failure: zqjs.Failure = .{};
    while ((try ex.@"resume"(10, &failure)) == .suspended) {}
}
```

See [examples/embed.zig](examples/embed.zig) for the full runnable example (`zig build example`).

---

### 11. C ABI (`include/zqjs.h`, `libzqjs.a`, M9.2)

ZQJS exports a C11/C++-compatible ABI in [include/zqjs.h](include/zqjs.h) backed by `libzqjs.a` ([src/c_api.zig](src/c_api.zig)). Running `zig build` installs both into `zig-out/include/zqjs.h` and `zig-out/lib/libzqjs.a`. Internally, the C ABI uses `std.heap.smp_allocator` (no allocator vtable or libc dependency required by `libzqjs.a`).

#### No Zig Panics Across the C Boundary
Every C ABI function returns `zqjs_status` rather than panicking or unwinding across C frames:
- **Null / invalid arguments:** required out-pointers or invalid `(ptr, len)` pairs return `ZQJS_ERR_INVALID_ARG`.
- **Stale / foreign handles:** every `zqjs_handle_*` and `zqjs_runtime_call` validates `rt` and `h` before dereferencing:
  - Released or wrong-generation handles (including `ZQJS_HANDLE_NULL`) return `ZQJS_ERR_STALE_HANDLE`.
  - Handles minted by another runtime return `ZQJS_ERR_FOREIGN_HANDLE`.
  - Wrong value kind in `zqjs_handle_number` / `zqjs_handle_boolean` / `zqjs_handle_string_utf16` returns `ZQJS_ERR_TYPE`.
- **Disallowed re-entrancy & concurrency:** calling into an active runtime from another thread, from inside `output_fn` / `clock_fn`, or calling host-only operations (`compile`, `start`, `run`, `define_global_function`, `*_destroy`) from inside a `zqjs_native_fn` callback returns `ZQJS_ERR_BUSY`. Calling `zqjs_runtime_throw_js` outside an active `zqjs_native_fn` returns `ZQJS_ERR_INVALID_STATE`.

#### Opaque Types, Destruction & Invalidation Semantics
- **`zqjs_runtime`:** created with `zqjs_runtime_create(opts, &rt)` (`opts == NULL` uses `zqjs_options_default()`); destroyed with `zqjs_runtime_destroy(rt)`. Destroying `rt` invalidates all remaining child `zqjs_program`s, `zqjs_execution`s, and `zqjs_handle`s owned by `rt`.
- **`zqjs_program`:** compiled with `zqjs_runtime_compile(...)`; destroyed with `zqjs_program_destroy(prog)`. Destroying `prog` invalidates `prog` immediately (`ZQJS_ERR_INVALID_STATE` on reuse), while any active `zqjs_execution`s keep the underlying compiled bytecode alive until they or `rt` are destroyed. Keep `prog` alive while closures compiled in it may still be invoked via `zqjs_runtime_call`, and while async calls started from it are still pending (settling the promise they await resumes the program's code).
- **`zqjs_execution`:** created with `zqjs_runtime_start(rt, prog, &exec)`, stepped via `zqjs_execution_resume(exec, steps, &fail)` (`ZQJS_STATUS_SUSPENDED` or `ZQJS_STATUS_FINISHED`), and freed with `zqjs_execution_destroy(exec)`.
- **`*_destroy(NULL)`** is a no-op returning `ZQJS_OK`; destroying an already-destroyed wrapper returns `ZQJS_ERR_INVALID_STATE`.

#### Native Callbacks (`zqjs_native_fn`), Result Transfer & Error Mapping
- **Borrowed temporaries:** `opt_this` (`NULL` when absent) and `args[0..argc-1]` are valid only during the `zqjs_native_fn` call; retain with `zqjs_handle_dup`.
- **Result transfer (`zqjs_native_out`):** set `out->has_result = true` and `out->result = h` to transfer ownership of `h` to the engine (copied before teardown releases `h`). To return a host-retained handle without consuming it, assign a `zqjs_handle_dup` copy. Invalid/stale `out->result` handles on `ZQJS_OK` map to `ZQJS_ERR_HOST` (`Failure.Kind.host`).
- **`host_message` lifetime:** `out->host_message` (`out->host_message_len`) is borrowed only until `zqjs_native_fn` returns and is copied into ZQJS's fixed 256-byte NUL-terminated `zqjs_failure.message` buffer (empty `host_message` on `ZQJS_ERR_HOST` defaults to `"host error"`).
- **Error mapping:** `ZQJS_ERR_THROWN` (paired with `zqjs_runtime_throw_js`) → `ZQJS_FAILURE_THROWN`; `ZQJS_ERR_HOST` → `ZQJS_FAILURE_HOST`; `ZQJS_ERR_LIMIT_EXCEEDED` → `ZQJS_FAILURE_LIMIT`; `ZQJS_ERR_UNSUPPORTED` → `ZQJS_FAILURE_UNSUPPORTED`; `ZQJS_ERR_OUT_OF_MEMORY` → `ZQJS_FAILURE_OUT_OF_MEMORY`; `ZQJS_ERR_INTERNAL` → `ZQJS_FAILURE_INTERNAL` (poisons runtime).

#### ABI Versioning & `zqjs_options` Compatibility
- **`ZQJS_ABI_VERSION` / `zqjs_abi_version()`:** encoded as `(major << 16) | (minor << 8) | patch` (`1.4.0` = `0x00010400u`). Major bumps only on breaking layout/signature/semantic changes; minor bumps on backward-compatible additive changes (new functions or trailing `zqjs_options` fields). Hosts should check `(zqjs_abi_version() >> 16) == ZQJS_ABI_MAJOR` at startup.
- **`zqjs_options.struct_size`:**
  - Always initialize with `zqjs_options_default()`, which sets `struct_size = sizeof(zqjs_options)` and populates all defaults (including `random_seed` and `max_native_stack_bytes`).
  - Passing `NULL` to `zqjs_runtime_create` uses `zqjs_options_default()`.
  - Smaller/older structs (`>= offsetof(zqjs_options, clock_ctx) + sizeof(void *)`) are accepted; omitted trailing fields (`random_seed`, `max_native_stack_bytes`) keep their defaults (`zqjs_limits` layout is unchanged across 1.0–1.4).
  - Zero, truncated, or oversized structs (`struct_size > sizeof(zqjs_options)`) are rejected with `ZQJS_ERR_INVALID_ARG`.

#### Structured Handles, Promises & Global Access (M12.2–M12.3, M29)
Both APIs support creating and inspecting JS objects, dense arrays, host promises, and runtime globals without flattening values across the boundary:
- **Zig (`Runtime`):** `newObject`, `newArray`, `newPromise`, `promiseState`, `getGlobal`, `getProperty`, `setProperty`, `getIndex`, `setIndex`.
- **C ABI:** `zqjs_new_object`, `zqjs_new_array`, `zqjs_new_promise`, `zqjs_handle_promise_state`, `zqjs_runtime_get_global`, `zqjs_handle_get_property`, `zqjs_handle_set_property`, `zqjs_handle_get_index`, `zqjs_handle_set_index`.
- **Ownership:** every returned handle is **owned** by the caller and must be released with `zqjs_handle_release` / `Handle.release()`. Input `obj` and `val` handles are **borrowed** and never consumed.
- **Semantics:** missing properties and out-of-range array indices return an owned `undefined` handle; `setIndex` enforces D13 dense arrays (`index == length` appends, `index > length` fails with `ZQJS_ERR_UNSUPPORTED`); `getGlobal` resolves runtime globals (`Math`, `Array`, `Object`, host-registered natives, `undefined`, `NaN`, `Infinity`) while preserving E3 fresh per-execution top-level script bindings.

```c
/* Pass structured state from C into JS and read back updated fields */
zqjs_handle state = ZQJS_HANDLE_NULL, count = ZQJS_HANDLE_NULL;
zqjs_failure fail;
assert(zqjs_new_object(rt, &state) == ZQJS_OK);
assert(zqjs_new_number(rt, 0.0, &count) == ZQJS_OK);
assert(zqjs_handle_set_property(rt, state, "count", 5, count, &fail) == ZQJS_OK);
zqjs_handle_release(rt, count); /* input handles are borrowed */

/* Read a nested property (caller owns the returned handle) */
zqjs_handle out_count = ZQJS_HANDLE_NULL;
assert(zqjs_handle_get_property(rt, state, "count", 5, &fail, &out_count) == ZQJS_OK);
double n = 0.0;
assert(zqjs_handle_number(rt, out_count, &n) == ZQJS_OK);
zqjs_handle_release(rt, out_count);
zqjs_handle_release(rt, state);
```

#### Examples & Raylib C-ABI Demo (M11.4, M12.4)
- **[examples/c_embed.c](examples/c_embed.c):** minimal standalone C11 embedding example linking `zig-out/lib/libzqjs.a` and `zig-out/include/zqjs.h`.
- **[examples/raylib_c_demo.c](examples/raylib_c_demo.c):** C11 Raylib host where JS owns `update(input)` / `draw()` / `state` via `initGame({ update, draw, state })` and C owns the frame loop, native drawing bindings, and error teardown.
  - **Prerequisites:** Raylib installed (auto-detected at `/opt/homebrew/opt/raylib` on macOS, via `pkg-config` elsewhere, or with `-Draylib-prefix=<path>`). Default `zig build` and `zig build test` do not require Raylib.
  - **Headless smoke test:** `zig build raylib-smoke` (runs `--frames 60 --verify-errors` without opening a GUI window).
  - **Interactive GUI:** `zig build raylib-demo` (opens the 800x480 Raylib window).

### 12. ES Modules & Host Module Loader (`setModuleLoader`, `runModule`, C ABI 1.3.0, D72)
- Register a host `ModuleLoader` via `rt.setModuleLoader(loader)` (or `zqjs_set_module_loader(rt, loader, ctx)` in C). The callback receives `(ctx, referrer_id, specifier)` and returns `{ canonical_id, source }` (or `error.ModuleNotFound` / `error.HostError`). The engine copies both strings immediately and invokes the optional `free` callback if provided.
- `rt.runModule(specifier, source, &diag, &failure)` (or `zqjs_eval_module` in C) loads, links, and evaluates the module graph on the VM, returning an owned `Handle` to the entry module's namespace object (`getProperty(ns, "exportedFn", ...)` + `rt.call(...)` to invoke exported JS functions directly).
- `rt.getModuleNamespace(specifier, &failure)` retrieves the namespace `Handle` for any already-loaded module in the runtime.
- Loaded modules and their exported closures/classes/cells remain GC-rooted by the `Runtime` until `Runtime.destroy()`.

### 13. Zero-Copy Binary Buffers (`newArrayBuffer`, `bufferBytes`, C ABI 1.4.0, D73)
- **Zig:** `try rt.newArrayBuffer(byte_len)` allocates a zero-initialized `ArrayBuffer` (counted against `Limits.max_heap_bytes`) and returns an owned `Handle`. `rt.bufferBytes(h)` returns `?[]u8` for an `ArrayBuffer` (full backing buffer), `TypedArray` (its view subslice), or `DataView` (its view subslice), or `null` for non-buffer handles.
- **C ABI:** `zqjs_new_array_buffer(rt, byte_len, &out_handle)` and `zqjs_handle_buffer_data(rt, handle, &out_ptr, &out_byte_len)` provide zero-copy pointer access (`ZQJS_ERR_TYPE` for non-buffer/detached handles, `ZQJS_ERR_STALE_HANDLE` for released handles).
- **GC safety:** the returned slice/pointer points directly into the `ArrayBuffer`'s non-moving heap backing store and stays valid while the `Handle` (or any JS view referencing that buffer) remains live and no GC/re-entry invalidates it.
