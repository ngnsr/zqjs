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
  - **Sanctioned re-entrant calls (succeed):** `rt.call`, `rt.newNumber`, `rt.newBoolean`, `rt.newStringUtf16`, `rt.throwJs`, `Handle` operations (`kind`, `number`, `boolean`, `string`, `dup`, `release`), `rt.collectGarbage`, and `rt.memory`.
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
  - `h.kind()` returns `HandleKind` (`.undefined`, `.null`, `.boolean`, `.number`, `.string`, `.function`, `.object`, `.array`).
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
- The error faults the execution like any other, and **poisons the runtime**: every later call that runs code or mints handles (`compile`, `start`, `run`, `resume`, `call`, `new*`, `dup`) returns `error.Internal` until `Runtime.destroy`.
- Handle readers/releases, `collectGarbage`, `memory`, and all destroy paths stay usable, so the host can still inspect and clean up.
- The CLI prints `internal error: <reason>` and exits with code 70; the `Failure` text itself stays the fixed `internal error`.

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
