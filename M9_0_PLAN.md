# M9.0 plan: the Zig embedding API

Status: **revision 2, for final review.** Nothing below is implemented.
- Round 1 approved the direction and decided questions 1, 2, 3 and 5.
- This revision:
  - answers question 4 (several executions);
  - makes ownership and destruction explicit (E1);
  - proves the step cap can't be bypassed (E4);
  - defines the failure text's truncation and UTF-8 behaviour;
  - adds the required tests.

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
pub const Failure = struct {   // filled when a call returns an error; never allocates
    kind: Kind,                // thrown, limit, unsupported, internal, out_of_memory, output
    limit: ?zqjs.Limit,
    /// e.g. "TypeError: x is not a function", "Unsupported(builtin): Math.PI" (rules: E10)
    text: [256]u8,
    text_len: usize,           // bytes of `text` in use, ≤ 256
    truncated: bool,
    pub fn message(f: *const Failure) []const u8; // text[0..text_len]
};
```

The names and exact shapes are open for review (see *Questions*). The behaviour below is
what M9.0 commits to.

## Semantics

**E1: ownership and destruction.** A strict hierarchy:

```
Runtime                      owns its heap, realm, root list and everything below
 ├── Program A               a GC root (its constants) from compile until released
 ├── Program B               (compiled, never run: still a root, still owned)
 ├── Execution 1 (of A)      its own VM (stacks, frames, pc); a GC root until destroyed
 └── Execution 2 (of B)
```

- **Nothing outlives its runtime.** `Runtime.destroy` releases every program and execution
  it still owns, in any order, along with their roots, the heap and the realm. Afterwards,
  every pointer the host still holds to them is dangling.
- **Destroying a program early.** `Program.destroy` drops the host's reference.
  - The program's root and memory are released once no execution of it remains: an execution
    keeps its program alive internally. So a host may destroy a program right after starting
    it.
  - After `Program.destroy` and a collection, its constants are freed. A test checks it.
- **Destroying an execution early.** `Execution.destroy` unregisters its roots immediately,
  whether it's suspended, finished or faulted.
- **Use after destroy** of any of the three, including through a runtime that's gone, is a host
  bug. Safe builds catch it at every entry point by a tag check that panics naming the type.
  That's best effort (memory may be reused), and documented as such.
- **Allocation.** No call allocates through anything but the runtime's allocator. There are no
  globals and no thread-locals.

**E2: threads.**
- A runtime is used by one thread at a time; calls never overlap.
- It may move between threads between calls.
- Separate runtimes are fully independent.

**E3: programs.**
- A program runs any number of times. Each start gets fresh top-level bindings.
- Runs of one runtime share its realm: a script that changes `Object.prototype` changes it
  for later runs too, as in any JS realm. That's documented, not prevented.
- A program is a GC root while it exists: its constants survive any collection.

**E4: two different budgets, and the cap can't be bypassed.**
- *The slice:* `resume(ex, steps)` runs at most `steps` instructions. When they run out, the
  result is `.suspended`: resumable, with nothing lost. Precision (D35) makes this exact: the
  next `resume` continues at the same instruction, charged once.
- *The cap:* `limits.max_steps` is the hard total for one execution, **cumulative over all its
  resumes**.
  - Each instruction is charged once to the execution's lifetime counter, which never resets.
    A slice only caps how much of the cap one call may spend.
  - When the counter reaches `max_steps`, the next instruction fails with
    `LimitExceeded(steps)`, and the execution is faulted.
  - For example: `max_steps` = 1 000 000, resumed in slices of 1000. The first 1000 resumes
    each spend a full slice and suspend; the 1001st faults on its first instruction. It never
    gets a second million.
- *Per execution, not per runtime:* a new execution gets a fresh cap. A host that keeps
  starting executions has chosen to; the API never refills a cap behind its back.
- So a game can slice a script across frames, and a runaway script still stops.

**E5: several executions, cooperative, never concurrent.**
- **What they share and don't.**
  - Each execution has its own VM: stacks, frames, `pc`, and its script's top-level `let` and
    `const`. Those are locals of its first frame: ZQJS has no writable globals, and assigning
    an undeclared name is `Unsupported(global_assignment)`.
  - All executions of a runtime share its heap and realm. A change to a built-in object (say
    `Object.prototype.x = 1`) is visible to the others, as in one JS realm.
  - Nothing else connects them in M9.0, because no values cross the API.
- **Cooperative:**
  - any number may exist, started, suspended, finished or faulted;
  - they're resumed one call at a time, in any interleaving;
  - a collection during one execution marks every registered execution and program.
- **Never concurrent:**
  - a runtime runs one call at a time (E2);
  - in M9.0 a call can't re-enter the runtime, because no natives exist;
  - in safe builds an "in a call" flag catches a host calling in while another call runs,
    from another thread or from its output writer.
- **Cost:** the runtime's single root slot becomes a list, which programs need anyway (E1).
  Executions stay registered for their whole lifetime instead of only while stepping.
- **Fallback, if implementation shows a cost not seen here:** one execution at a time
  (`start` returns `error.Busy` while another is unfinished). The API wouldn't change: adding
  several later is purely additive.

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

**E10: failure text.** `Failure.text` is filled without allocating, and is always valid UTF-8.
- **Encoding.** Messages are UTF-16 inside ZQJS. They're converted the way `print` does it:
  pairs become 4-byte sequences, and a lone surrogate becomes U+FFFD.
- **Truncation.** If the text doesn't fit in 256 bytes, it's cut at a code point boundary,
  never inside a UTF-8 sequence, and ends with "…" (U+2026, 3 bytes). `truncated` is set, and
  `text_len` stays ≤ 256.
- **No NUL terminator.** The Zig API doesn't add one; the C ABI (M9.2) will, in its own
  buffer.
- **Kinds without a script message:** `out_of_memory`, `output` and `internal` get a fixed
  English text.

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
  - **(required by review) several programs compiled but never run, then the runtime
    destroyed:** no leak (leak-checking allocator), and nothing left registered. With the
    leak check under gc-stress, a forgotten root fails either as a leak or as a use after
    free;
  - `Program.destroy` before the runtime: after a collection, `memory().bytes` is back to
    its value before the compile. The same with an execution of it started, run, then
    destroyed (the execution kept the program alive until then);
  - a program compiled once and run 3 times gives the same output each time;
  - a compile error leaves a usable runtime, with the right message, line and column.
- **Slices change nothing** (the core test). Every `tests/diff` program runs through the API
  with slices of 1, 7 and 1000 steps and unbounded, and each output must equal node's `.out`.
  Under gc-stress that also collects between resumes.
- **Several executions (E5):**
  - 3 executions of different programs, suspended and resumed interleaved, with garbage, each
    output exact;
  - a major collection between resumes keeps every suspended execution's values;
  - two executions of the *same* program each get their own top-level bindings;
  - a change to a built-in made by one execution is seen by the other (the shared realm);
  - destroying one suspended execution doesn't disturb the others;
  - in safe builds, a call into a runtime from its own output writer during `resume` is caught
    as a host bug.
- **The step cap holds across resumes (E4):**
  - a script that never ends, with `max_steps` = 1000, resumed in slices of 1: exactly 1000
    `.suspended`, then `LimitExceeded(steps)` on the 1001st resume;
  - slices of 7, 1000 and maxInt give the same end, after the same total;
  - a second execution gets a fresh cap; the faulted one stays faulted.
- **Errors:**
  - `max_steps` → `LimitExceeded(steps)`; that execution is faulted, and a new one runs fine;
  - `Thrown` and `Unsupported` give the right `Failure` text;
  - E10's text rules:
    - a message longer than 256 bytes is cut at a code point boundary and ends in "…", with
      `truncated` set;
    - a surrogate pair right at the cut point is either whole or cut before it;
    - a lone surrogate comes out as U+FFFD;
    - the result is always valid UTF-8 (`std.unicode.utf8ValidateSlice`);
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

## Review decisions

| question | decision |
|---|---|
| 1. opaque types or plain structs | **Opaque types** (round 1) |
| 2. slice exhaustion suspends, `max_steps` faults | **Approved** (round 1). E4 adds the cumulative cap and its tests |
| 3. the runtime owns everything | **Approved** (round 1), with E1's explicit hierarchy and destruction rules |
| 4. several executions | **Proposed: yes, cooperative, never concurrent** (E5). The fallback is one at a time, with an unchanged API. *For final review* |
| 5. internal errors poison the runtime | **Approved** (round 1) |
| 6. a fixed 256-byte message | **Conditionally approved** (round 1). E10 defines truncation and UTF-8. *For final review* |
