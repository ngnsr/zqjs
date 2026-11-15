# Embedding ZQJS in Zig

ZQJS is designed from the ground up to be embedded in host applications (game loops, simulation engines, command-line tools). The embedding API provides host control over execution time, resource limits, and memory, without exposing the virtual machine's internal structures.

To embed ZQJS, your Zig build only requires the `zqjs` module. All engine internals (`Vm`, `Proto`, `Heap`, GC cards and bitmaps) stay private and inaccessible.

---

## Architecture & Concepts

The embedding API is built around three **opaque handles**:

```
Runtime                       owns heap, realm, root list, and everything below
 ├── Program A                compiled bytecode and constants; reusable GC root
 ├── Program B                compiled, never run; safely reclaimed on destroy
 ├── Execution 1 (of A)       isolated VM state (frames, pc, stacks, locals)
 └── Execution 2 (of A)       second run of A with independent local variables
```

### 1. Ownership & Lifecycle (E1)
- **Nothing outlives its runtime:** `Runtime.destroy(rt)` immediately tears down all active programs and executions, releases all registered GC roots, and frees the heap and realm. Any host pointers held after `destroy` are invalid.
- **Reference-counted Programs:** A compiled `*Program` has an internal reference count: one for the host's handle, plus one for every active `*Execution` started from it.
  - Calling `Program.destroy(prog)` invalidates the host handle immediately.
  - Any active executions of that program continue running unaffected, retaining the bytecode and string constants as GC roots.
  - The program's constants and bytecode are freed once the last execution is destroyed, or when the runtime is destroyed, whichever comes first.
- **Early Execution Destruction:** Calling `Execution.destroy(ex)` drops its VM stacks and unregisters its GC roots immediately, regardless of whether it is running, suspended, or faulted.

### 2. Thread Safety & The Entry Guard (E2)
- A runtime is strictly single-threaded at any instant: calls into a runtime or any object it owns must never overlap.
- Every API call claims an internal atomic entry guard (via atomic compare-and-swap) and releases it on return.
- If two calls overlap—whether from two racing threads or from a host output writer attempting to re-enter the runtime—it is caught as a host bug and immediately panics:
  ```
  zqjs: Runtime entered while another call into it is running
  ```
- Runtimes are fully independent: separate runtimes may run concurrently on different threads without locks.

### 3. Compilation: Compile Once, Run Many (E3)
- Scripts are compiled with `rt.compile(name, source, &diag)`. Compilation parses, resolves scopes, compiles to bytecode, and verifies bytecode integrity.
- On syntax, scoping, or source limit errors, `compile` returns `error.Source` and populates `Diagnostic` with the message, line, and column. The runtime heap is automatically rolled back to its pre-compilation state.
- A compiled `*Program` can be started any number of times via `rt.start(prog)`. Each start receives a fresh top-level scope and fresh local variables.
- All executions on a runtime share its JavaScript realm: prototype modifications (e.g. adding properties to `Object.getPrototypeOf({})`) are visible across executions.

### 4. Cooperative Multitasking & Step Budgets (E4, E5)
ZQJS separates step scheduling into two distinct concepts:

- **The Slice (`steps` in `resume`):** How many VM instructions the host permits this call to run. When the slice expires with the script unfinished, `resume` returns `.suspended`. The execution pauses safely with zero loss of state and can be resumed in the next frame.
- **The Cap (`limits.max_steps`):** The cumulative total instruction limit across all resumes for a single execution. It prevents runaway or infinite loops.

#### Exact Cap Semantics
- Each instruction increments the execution's lifetime counter.
- **Slice expires:** if the slice budget runs out before the cap, the call returns `Status.suspended`.
- **Tie:** if the slice and the cap end on the exact same instruction with the script unfinished, it returns `Status.suspended`. The *next* resume attempt fails with `error.LimitExceeded`.
- **Completion at cap:** if a script finishes (including its `halt` opcode) at or before `max_steps`, it completes with `Status.finished`, never an error.
- **Budget 0:** calling `ex.@"resume"(0, null)` runs zero instructions and returns `.suspended` (or `.finished` if already done).
- **Fault persistence:** once an execution hits a limit or throws an uncaught error, it is faulted. Further `resume` calls immediately return the same error. Other executions on the same runtime remain unaffected.

### 5. Non-Allocating Errors & Diagnostics (E8, E10)
Script errors never panic. Errors are returned as standard Zig errors alongside a non-allocating `Failure` or `Diagnostic` record:

```zig
pub const Failure = struct {
    kind: Kind,                // thrown, limit, unsupported, out_of_memory, output, internal
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

---

## Embedding Quickstart

Here is a minimal, complete host program compiling and stepping two scripts cooperatively:

```zig
const std = @import("std");
const zqjs = @import("zqjs");

pub fn main() !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    // 1. Create runtime with limits and output writer
    var out_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(std.Io.getStd(), &out_buf);
    const rt = try zqjs.Runtime.create(gpa, .{
        .limits = .{
            .max_heap_bytes = 4 * 1024 * 1024,
            .max_steps = 100_000,
        },
        .output = &stdout.interface,
    });
    defer rt.destroy();

    // 2. Compile scripts
    var diag: zqjs.Diagnostic = .{};
    const prog1 = rt.compile("worker1.js", "for (let i = 0; i < 3; i++) { print('worker 1:', i); }", &diag) catch |e| {
        std.debug.print("Compile error: {s}\n", .{diag.message()});
        return e;
    };
    defer prog1.destroy();

    const prog2 = rt.compile("worker2.js", "for (let i = 0; i < 3; i++) { print('worker 2:', i); }", &diag) catch |e| {
        std.debug.print("Compile error: {s}\n", .{diag.message()});
        return e;
    };
    defer prog2.destroy();

    // 3. Start executions
    const ex1 = try rt.start(prog1);
    defer ex1.destroy();

    const ex2 = try rt.start(prog2);
    defer ex2.destroy();

    // 4. Interleave executions in slices of 5 steps
    var st1: zqjs.Status = .suspended;
    var st2: zqjs.Status = .suspended;
    var failure: zqjs.Failure = .{};

    while (st1 == .suspended or st2 == .suspended) {
        if (st1 == .suspended) {
            st1 = try ex1.@"resume"(5, &failure);
        }
        if (st2 == .suspended) {
            st2 = try ex2.@"resume"(5, &failure);
        }
    }

    const mem = rt.memory();
    std.debug.print("Done! Live heap: {d} bytes, peak: {d} bytes\n", .{ mem.bytes, mem.peak });
}
```

See [examples/embed.zig](examples/embed.zig) for a full runnable example (`zig build example`).
