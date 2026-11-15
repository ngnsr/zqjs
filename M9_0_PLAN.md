# M9.0 plan: the Zig embedding API

Status: **proposal, for review.** Nothing below is implemented.

Scope, from ROADMAP.md (Direction):
- lifecycle;
- compile once, run many;
- execution under limits and step budgets;
- results instead of panics.

Values crossing the boundary, native functions and handles are M9.1. The C ABI is M9.2. The
API keeps the VM private: no `Proto`, heap, stack layout or GC detail is reachable from it.

## What exists today, and what it forces

| fact (today's code) | consequence for the API |
|---|---|
| `src/root.zig` exports everything: `ast`, `heap`, `Vm`, `bytecode`, `compile`… Tests and tools use these internals. | Public and internal need separate **modules**. Zig won't put one file in two modules, so two root files aren't enough. |
| A compiled `Proto` keeps its string constants on the heap of the runtime it was compiled for. Only the running VM roots them (`markProto`). | A program belongs to one runtime, and **is a GC root for as long as it exists**, not only while it runs. |
| `Runtime.engine_roots` holds one engine. | Several suspended executions need a **list** of registered roots. |
| `step()` is precise (D35): an error leaves `pc`, frames and stacks as before the instruction, and the budget is charged *before* it. | Running out of a *slice* budget can **suspend** an execution, and resuming continues exactly where it stopped. |
| VM defensive checks panic (`bug`, D35, a debt item). | They become an **internal-error result**. |
| The tree-walker recurses natively (D37). It can't stop mid-script. | **The API is VM-only.** The tree-walker stays the oracle behind `--engine=treewalk`. |
| `print` writes to `Runtime.out`. | Output is an option: the host's writer, or none. |

## The API

Three **opaque** types. Their state is only reachable through functions, so internals can't
leak into an embedder's code. They also map one-to-one onto M9.2's C handles.

```zig
const zqjs = @import("zqjs"); // the public module: nothing else is reachable

pub const Options = struct {
    limits: zqjs.Limits = .{},         // heap, string length, call depth… (D15)
    output: ?*std.Io.Writer = null,    // where `print` writes; null: discarded
};

pub const Runtime = opaque {
    pub fn create(gpa: Allocator, options: Options) error{OutOfMemory}!*Runtime;
    pub fn destroy(rt: *Runtime) void;          // also destroys its programs and executions

    /// Parse, resolve, compile and verify. On a source error returns error.Source;
    /// `diag` (if given) gets the message, line and column.
    pub fn compile(rt: *Runtime, name: []const u8, source: []const u8, diag: ?*Diagnostic) CompileError!*Program;

    /// Start running `program` from its first instruction (fresh top-level bindings).
    pub fn start(rt: *Runtime, program: *Program) StartError!*Execution;

    /// Convenience: start + resume until finished. Honors limits.max_steps.
    pub fn run(rt: *Runtime, program: *Program, failure: ?*Failure) RunError!void;

    pub fn collectGarbage(rt: *Runtime) void;    // a major collection, now
    pub fn memory(rt: *const Runtime) Memory;    // bytes, peak, collections (numbers only)
};

pub const Program = opaque {
    pub fn destroy(p: *Program) void;  // optional before Runtime.destroy
};

pub const Execution = opaque {
    /// Run at most `steps` instructions. `.finished`: the script completed. `.suspended`:
    /// the slice ran out, and nothing is lost; call resume again (next frame, for a game).
    pub fn resume(ex: *Execution, steps: u64, failure: ?*Failure) RunError!Status;
    pub fn destroy(ex: *Execution) void;
};

pub const Status = enum { finished, suspended };
pub const RunError = error{ Thrown, LimitExceeded, Unsupported, OutOfMemory, OutputFailed, Internal };
pub const Failure = struct {   // filled when a call returns an error
    kind: Kind, // thrown, limit, unsupported, internal
    limit: ?zqjs.Limit,
    /// Copied into `text` (UTF-8, truncated with "…" if it doesn't fit), e.g.
    /// "TypeError: x is not a function" or "Unsupported(builtin): Math.PI".
    text: [256]u8, text_len: usize,
};
```

The names and exact shapes are open for review (see *Questions*). The behaviour below is
what M9.0 commits to.

## Semantics

**E1: ownership.**
- A runtime owns everything created from it.
  - `destroy` on a program or execution is optional.
  - `Runtime.destroy` frees what's left, in any order.
- Using a program or execution after its runtime, or after itself, is destroyed is a host bug.
  In safe builds it's caught by a tag check at every entry point, which panics with the type's
  name. That's best effort, and documented as such.
- No call allocates through anything but the runtime's allocator. There are no globals and no
  thread-locals.

**E2: threads.**
- A runtime is used by one thread at a time; calls never overlap.
- It may move between threads between calls.
- Separate runtimes are fully independent.

**E3: programs.**
- A program runs any number of times. Each start gets fresh top-level bindings.
- Runs of one runtime share its realm: a script that changes `Object.prototype` changes it
  for later runs too, as in any JS realm. That's documented, not prevented.
- A program is a GC root while it exists: its constants survive any collection.

**E4: two different budgets.**
- *The slice:* `resume(steps)` is a soft budget. When it runs out, the result is `.suspended`,
  resumable, with nothing lost. Precision (D35) makes this exact: the next `resume` continues
  at the same instruction, charged once.
- *The cap:* `limits.max_steps` is the hard total for one execution. Reaching it is
  `LimitExceeded(steps)`, and the execution is faulted.
- So a game can slice a script across frames without a runaway script running forever.

**E5: several executions.**
- Any number of executions can exist at once, started, suspended or finished, of one program
  or several. Their roots are a list, so a collection in one keeps every other's values alive.
- Only one runs at a time (E2).

**E6: errors leave the runtime usable.**
- `Thrown`, `LimitExceeded`, `Unsupported`, `OutOfMemory` and `OutputFailed` fault that
  *execution*: further resumes return the same error. The runtime stays usable: new
  executions and other programs run normally.
- That's true even after `OutOfMemory` at any allocation, because calls are transactional and
  allocation failure leaves the heap sound. Allocation-failure tests prove it.

**E7: internal errors never panic.**
- A failed VM defensive check returns `Internal`, and so does a verifier rejection of compiled
  code. Both are bugs in ZQJS, never in the script.
- After `Internal` the *runtime* is poisoned: every call returns `Internal`, and only
  `destroy` works. A failed check means the VM's own state can't be trusted.

**E8: compile errors.** A syntax, resolution or source-limit error returns `error.Source`,
with the message and position in `diag`. The runtime is unchanged and usable (`Heap.rollback`
already guarantees it).

**E9: output.** `print` writes to `Options.output`, or nowhere. A failing writer makes the call
return `OutputFailed`, so output is never lost silently.

## Internal changes (the API keeps all of them hidden)

1. **Two modules.**
   - `zqjs` (root `src/api.zig`): the public API, built on the internal module.
   - `zqjs_internal` (today's `src/root.zig`): everything. Tests, tools and the CLI's debug
     modes import it.
   - An embedder's build gets only `zqjs`.
2. **Roots.** `Runtime.engine_roots` becomes a list. Programs register their protos as roots
   until destroyed.
3. **Two step budgets.** A per-resume slice next to the per-execution cap. Running out of the
   slice is a new `step()` outcome, not an error, so the VM isn't faulted.
4. **Defensive checks return errors** (`error.Internal`) instead of panicking. It's the same
   compare, and only the failure path changes (D35 revised).
5. **The CLI's default path uses the public API**, so the API runs on every `zqjs file.js`.
   `--engine=treewalk`, `--trace` and the dump modes keep using internals.

## Acceptance criteria

All tests below run in the normal build and under `-Dgc-stress -Dstack-stress`, and in
ReleaseSafe in CI.

- **The public surface is pinned.**
  - `tests/api_test.zig` imports only `zqjs`, so it can't reach internals: the build fails if
    it tries.
  - A snapshot test lists `zqjs`'s public declarations and fails on any change. A new export
    is a reviewed decision.
- **Lifecycle:**
  - create and destroy leak nothing;
  - `Runtime.destroy` with live programs and executions frees them all;
  - a program compiled once and run 3 times gives the same output each time;
  - a compile error leaves a usable runtime, with the right message, line and column.
- **Slices change nothing** (the core test). Every `tests/diff` program runs through the API
  with slices of 1, 7 and 1000 steps and unbounded, and each output must equal node's `.out`.
  Under gc-stress that also collects between resumes.
- **Several executions:**
  - 3 executions of different programs, suspended and resumed interleaved, with garbage, each
    output exact;
  - a major collection between resumes keeps every suspended execution's values.
- **Errors:**
  - `max_steps` → `LimitExceeded(steps)`; that execution is faulted, and a new one runs fine;
  - `Thrown` and `Unsupported` give the right `Failure` text;
  - a writer that fails → `OutputFailed`;
  - `checkAllAllocationFailures` over create → compile → start → resume → destroy: every
    failure returns `OutOfMemory`, leaks nothing, and leaves the runtime usable (E6).
- **Internal errors (E7).** An internal test, through `zqjs_internal`, forces a defensive-check
  failure (a hand-corrupted proto that skips the verifier). The result is `Internal`, not a
  panic; the runtime is poisoned, then destroyed cleanly.
- **Example.** `examples/embed.zig`: a host runs a script in slices of N steps per "frame" and
  prints its output. Built and run by `zig build example`, and in CI.
- **Docs.**
  - `EMBEDDING.md`: the API, E1–E9, an example.
  - DESIGN_DECISIONS D46: public and internal modules. D47: opaque types and ownership. D48:
    executions, slices and the cap. D49: internal errors as results (D35 revised).
  - ROADMAP: M9.0's regression tests. README: an embedding section.

## Not in M9.0

- **Values across the boundary:**
  - no reading results;
  - no host globals;
  - no calling a JS function from the host.

  All of that needs GC-safe handles, which are M9.1 and get their own design review.
- **Native functions and callbacks** (M9.1).
- **The C ABI** (M9.2). The opaque types are chosen so it's a thin layer.
- **The tree-walker in the API:** it can't suspend.
- **Exposing the GC observer, or choosing minor or major collections:** `memory()` returns
  numbers only.
- **Sharing compiled programs across runtimes:** they're tied to one heap. That's a possible
  later change, if an embedder needs it.
- **Interrupting a running `resume` from another thread:** slices bound the time a call can
  take instead.

## Questions for review

1. **Opaque types** (real privacy, a one-to-one C mapping) or plain structs with fields
   documented as private?
2. **Slice exhaustion suspends** (E4), and only `max_steps` faults. Or should one budget do
   both?
3. **Runtime-owned cascade** (E1): destroy in any order. Or strict ownership, where destroying
   a runtime with live programs is a caught bug?
4. **Several executions** in M9.0 (E5)? Or one at a time, deferring the root list to M9.1?
5. **Internal errors poison the runtime** (E7), not only the execution: agreed?
6. **`Failure` text** in a fixed 256-byte buffer, which allocates nothing and maps straight to
   C. Or an allocating message?
