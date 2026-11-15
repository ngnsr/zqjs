# M9.1 plan: values, natives and handles across the boundary

Status: **revision 2 — decisions frozen, awaiting P1 approval.** Revision 1 was reviewed
decision-by-decision; every open question is now answered and recorded below. Nothing is
implemented yet. If this revision passes review (the lifecycle diagram is the last gate),
P1 closes and implementation begins. M9.0 (tagged `m9.0`, in `main`) defined the shape the
API grows in; this plan contradicts nothing in it without saying so.

Scope, from ROADMAP.md (M9.1):
- values crossing the boundary in both directions;
- native functions callable from JavaScript;
- JavaScript functions callable from the host;
- GC-safe handles with explicit ownership;
- re-entrant execution semantics.

The C ABI stays M9.2 (a thin layer on what this plan settles).

## The requirements this plan is organized around

**R1 (review requirement): a native function must be able to call back into JavaScript
without invalidating VM state.**

**R2 (review requirement, added in review): native callback execution must remain safe under
GC stress.** Concretely, the chain that must hold under `-Dgc-stress`:

```
JS object → native receives handle → native calls back into JS
→ JS allocates → GC runs → native resumes and uses its handle
```

The original object must still be valid at the end. This is a named acceptance test (below).

What re-entrancy touches in today's engine, and what the frozen design does about each:

| fact (today's code) | what re-entrancy forces | frozen answer |
|---|---|---|
| `Native.call` borrows its argument slice (`value.zig`, D12/D40 comment: "it cannot call back into JS, so the stack cannot move under it"). | Arguments must be stable for the whole call. | Arguments cross as **temporary GC-rooted handles** (Q1). The borrowed slice is superseded; D12's `NativeCtx` idea is dropped — tokens do its job. (The slice also happens to stay valid, since the outer VM suspends under model B, but nothing relies on that.) |
| A native is called mid-instruction; D35's contract is one instruction = one step. | A nested JS call makes the outer instruction span many steps. | D35 gains a third clause (below): a `.call` to a host native spans the callee's steps and is precise at its own boundary. The **slice** may be overshot; the **cumulative budget** never is (Q8). |
| `Runtime.engine_roots` is one optional slot (`runtime.zig`); `extra_roots` is a list. | Two VMs are alive at once under the chosen model. | Both register through the **shared execution context** (below), which owns the active-VM root list. |
| The entry guard (E2) panics on any overlap, same thread included. | Re-entry from a native is not overlap; it is the same thread going deeper. | The guard becomes a **per-depth entry-kind stack** (`host`/`engine`) with an internal-only, callback-scoped capability. Host re-entry and cross-thread use still panic — every M9.0 expected-panic test stays green unchanged (Q7/Q12). |
| `Value.string/.object/.closure` are heap pointers; the collector may free them. | Any value the host holds across a call or a collection must be a handle. | The **handle table** (Q2–Q4): reference-counted slots, generation-checked tokens. GC_DESIGN §4's reserved "Host handles (M9)" line becomes real. |

Also true today, and unchanged by this plan unless a decision below says otherwise:
- `Native` has no context field (`value.zig`): host natives carry state through
  `defineGlobalFunction`'s `ctx` instead, which the runtime borrows and never touches.
- Conversions never call user functions (`Unsupported(user_conversion)`, D40) — **kept** (Q9).
- `max_call_depth` counts frames inside one VM; under model B the logical call depth is one
  shared counter in the execution context, charged by every VM's frames *and* by native records.
- The tree-walker is the oracle and stays out: host natives run on the VM only.
- A poisoned runtime (E7/D49) rejects every new crossing: no native callback starts, no
  handle is minted, `compile`/`start`/`run` return `Internal`; destroy paths stay available.

## The frozen decisions

| # | decision (frozen by review) |
|---|---|
| Q1 | Native arguments are **temporary GC-rooted handles**, owned by the engine's native-call record, released when the record tears down — on every outcome. |
| Q2 | Handle representation: **runtime handle table + generations** (per-slot generation counters; "generation", not "epoch", to keep GC's generational term unambiguous). |
| Q3 | Release model: **per-handle ownership tokens over reference-counted value slots**. The generation check validates the *token*, not merely the slot. |
| Q4 | Ownership: explicit `dup`/`release`; no scopes in M9.1 (additive later). |
| Q5 | **`error.HostError`**: a host operation failed; the execution faults with a host-facing classification and message. It does not poison the runtime. No RangeError abuse for host failures. |
| Q6 | Host globals live in the realm: `defineGlobalFunction`. **Duplicate names are rejected — including built-in names.** `ctx` is **borrowed by the runtime until `Runtime.destroy`**; ZQJS never frees or touches it; no destructor callback in M9.1. |
| Q7 | A native may call back into: `rt.call`, handle operations, `throwJs`, `collectGarbage`, read-only `memory`. `compile`/`start`/`run` during an active callback return **`error.Busy`**. The existing panics for accidental host API re-entry and cross-thread access are kept. |
| Q8 | `rt.call` runs to completion under the **shared cumulative budget**; no slicing in M9.1. Synchronous native callbacks may **overshoot a `resume()` slice** but never the cumulative `max_steps`. Budget exhaustion **latches** and faults the outer execution at the native boundary (specified under *Step budgets*). |
| Q9 | D40 stands: user `valueOf`/`toString` stay `Unsupported(user_conversion)`. |
| Q10 | Strings get handles like everything else (uniform model). `Handle.string(buf)` returns the **full length** and signals a wrong-kind handle **separately**; copying into a caller buffer never allocates, so no `OutOfMemory`. |
| Q11 | Re-entrancy mechanism: **model B — separate nested VM executions** — for M9.1. Model A is a future optimization, revisited only if a feasibility prototype justifies it (measured nested-VM creation cost). |
| Q12 | Host-driven re-entry from inside a native (the host's own code calling the public API mid-callback) is **rejected: panic**, no exception carved out. |

## The three API surfaces (sketches; names go through the snapshot test, D46)

```zig
pub const Handle = opaque {      // a GC-safe reference to one JS value
    pub fn kind(h: *const Handle) Kind;     // undefined, null, boolean, number,
                                            // string, function, object, array
    // Reading leaf values copies, under the guard; never allocates (Q10):
    pub fn number(h: *const Handle) ?f64;   // null = wrong kind
    pub fn boolean(h: *const Handle) ?bool; // null = wrong kind
    /// Wrong kind → null. Otherwise the string's full UTF-16 length; copies
    /// min(len, buf.len) units, so a too-small buf truncates visibly (len > buf.len)
    /// rather than silently. Never allocates (Q10): no error set.
    pub fn string(h: *const Handle, buf: []u16) ?usize;

    /// Same value, new independently owned token; the slot's reference count +1 (Q3/Q4).
    pub fn dup(h: *const Handle) error{OutOfMemory}!*Handle;
    /// Kills this token; slot reference count −1; the slot (and its rooting) dies at 0.
    pub fn release(h: *Handle) void;
};

pub const Runtime = opaque {
    // ... M9.0 declarations unchanged, plus:

    /// Host → JS. Calls `f` with `this` and the arguments, runs it to completion
    /// under the shared cumulative budget (Q8: no slicing in M9.1), returns the
    /// result as a token the caller owns.
    pub fn call(rt: *Runtime, f: *Handle, this: ?*Handle, args: []const *Handle,
                failure: ?*Failure) RunError!*Handle;

    /// JS → host. Registers a host native as a global function under `name` (Q6).
    /// Duplicate names — including built-in names — are `error.NameTaken`; the realm
    /// is left unchanged. `ctx` is borrowed until `Runtime.destroy` (Q6).
    pub fn defineGlobalFunction(rt: *Runtime, name: []const u8,
                                native: *const NativeFn, ctx: ?*anyopaque)
        error{ OutOfMemory, NameTaken }!void;

    /// Host values into JS. Each mints a token the caller owns.
    pub fn newNumber(rt: *Runtime, n: f64) error{OutOfMemory}!*Handle;
    pub fn newBoolean(rt: *Runtime, b: bool) error{OutOfMemory}!*Handle;
    pub fn newStringUtf16(rt: *Runtime, units: []const u16) error{OutOfMemory}!*Handle;

    /// JS → host failure for a deliberate JS exception (Q5/Q7): kind + UTF-16 message,
    /// converted through the E10 rules for the Failure text. Must be paired with
    /// returning error.Thrown; throwing without doing so is a host bug (checked).
    pub fn throwJs(rt: *Runtime, name: ErrorName, message: []const u16) void;
};

/// A host native (Q1/Q5). Runs with the guard held at depth ≥ 1: it may call back
/// into JS through the sanctioned API (Q7). `this` and `args` are temporary tokens
/// owned by the engine's native-call record — valid only during the call, released
/// automatically on every outcome; a native that wants to keep one must `dup` it.
pub const NativeFn = fn (rt: *Runtime, ctx: ?*anyopaque, this: ?*Handle,
                         args: []const *Handle, out: *NativeOut) NativeError;

pub const NativeOut = struct {
    /// Set on success (null → JS `undefined`). Ownership of the token moves to the
    /// engine, which copies its value into the caller's operand slot and releases it.
    result: ?*Handle = null,
    /// Set on error.HostError (Q5): the engine copies it into the Failure before
    /// the native's stack unwinds.
    host_message: []const u8 = "",
};

pub const NativeError = error{ Thrown, HostError, LimitExceeded, Unsupported, OutOfMemory, Internal };
// Thrown  — a JS-visible event; must be paired with rt.throwJs (checked).
// HostError        — a host operation failed; faults the execution with out.host_message
//                    and a host classification in the Failure; does NOT poison (Q5).
// LimitExceeded / Unsupported / OutOfMemory — as in M9.0 (E5/E6): fault the execution,
//                    runtime stays usable.
// Internal — a host bug: a native must never return it; the poison belt catches one
//                    anyway (E7/D49).
// (OutputFailed is absent: a native produces no output — the runtime's writer does.)
```

`HostError` joins the public error sets (`resume`/`run`/`call` can fault with it) and the
`Failure` gains a host classification — both are snapshot-reviewed additions (D46).

## Model B: separate nested VM executions (Q11, frozen)

The outer VM is **suspended** while a host native runs — nothing mutates its stacks — and the
nested JS call runs on a fresh `Vm` sharing the runtime's heap and realm. `rt.call` and the
native path share one implementation ("run a closure on a VM"), so the machinery is built
once and used by both.

- *Chosen because:* no surgery in the VM's heart — frames (D36), transactional calls,
  `reserve`, and `-Dstack-stress` all stay exactly as they are; the existing stack invariants
  are untouched; GC traces all active VMs through the execution context's root list; and the
  public API would not change if model A were folded in later.
- *Accepted costs:* a deep native→JS→native chain costs a whole VM per level (memory and
  per-level init); the nested call is not a frame of the outer call, so semantics diverge
  from JS in ways tests must pin — but with no `arguments`, no `new.target`, no stack traces,
  nothing in the current language subset observes the difference.
- *The refinement that makes B sound:* a **shared execution context** (below) so the nested
  model cannot accidentally hand every nested call a fresh budget or a private depth counter.
- *Model A (same VM, nested native frames with stable argument storage) is recorded as the
  future optimization,* not a fallback to be pulled in quietly: revisiting it requires a
  feasibility prototype that measures nested-VM creation cost and shows it matters. Model C
  (never-moving stacks) stays deferred to M10 as in revision 1.

## The shared execution context (model B's spine)

One per top-level entry (a `resume` of an execution, or a host `rt.call` at guard depth 0).
It lives on the runtime and owns exactly the four things the review named:

1. **The cumulative instruction budget.** `{ used, max = limits.max_steps }` — E4's
   per-execution cumulative counter, but *shared by every VM and native record in the chain*.
   A nested call never installs a fresh budget: it charges the same counter through the
   existing `rt.step()` (which checks `used ≥ max` before charging, so the counter can never
   exceed `max_steps`, E4). Budget exhaustion **latches** in the execution context, with
   exactly this semantics (review-frozen):
   - the first exhaustion latches `LimitExceeded` in the shared execution context;
   - subsequent nested JS execution cannot consume more instructions (`rt.step()` faults
     immediately);
   - the native may finish its current callback, but cannot clear or replace the latched
     failure;
   - when the native boundary is reached, the outer execution faults with the latched
     `LimitExceeded`, **regardless of the native callback's return value** — a native cannot
     turn a budget failure into success.
2. **The logical call-depth counter.** Charged by every VM's frames *and* by every native-call
   record, checked against `limits.max_call_depth` across the whole chain — no per-VM counters
   to keep in step.
3. **The re-entry state.** The guard's entry-kind stack and owner thread (next section) live
   here.
4. **The active-VM root registrations.** The list the collector traces (the `extra_roots`
   pattern, E5). Every VM registers on creation and deregisters on teardown; a *suspended*
   VM (mid-instruction, native in flight) stays registered for its whole suspension — that is
   what keeps its operand stacks, and everything they reference, alive across the nested
   descent.

For a top-level host `rt.call` (guard depth 0), the context is created fresh with
`used = 0`; for `Execution.resume`, the context adopts `E.used` and saves it back on return
(E4 unchanged: cumulative over the execution's resumes).

## Handles: tokens over reference-counted slots (Q2–Q4, frozen)

**Slots.** The runtime owns a growable table of value slots:

```zig
const Slot = struct {
    value: Value,          // the JS value; rooted while refs > 0
    refs: u32,             // how many tokens own this slot
    generation: u32,       // bumped each time the slot is freed to the free list
};
```

The table is **one root set**: the collector traces every slot with `refs > 0`. A value the
host holds stays alive exactly as long as some token references it; releasing the last token
makes it collectible again (`memory().bytes` before/after proves it).

**Tokens.** A token is one independently owned reference to a slot, allocated from a
runtime-owned token pool that is *never* freed per-token (only `Runtime.destroy` frees the
pool):

```zig
const Token = struct {
    runtime_id: u64,       // which runtime minted it (global atomic counter)
    slot: u32,             // index into the handle table
    generation: u32,       // the slot generation at mint time
    state: enum { live, dead },
};
```

- **Validation is token-level (Q3):** every API taking a handle first checks
  `state == .live` and `token.generation == slot.generation`. A released token is *dead*,
  deterministically detectable in safe builds **while its runtime is alive** — the record
  still exists (the pool never freed it), so the check can run. This is the fix for
  revision 1's flaw, where `release` freed the wrapper and made use-after-release
  undetectable even in safe builds.
- **Cross-runtime tokens are rejected by identity:** `token.runtime_id != rt.runtime_id`
  panics (a host bug), deterministically while both runtimes are alive.
- **`dup`** mints a new token for the same slot and increments `slot.refs`. Copying a token
  *value* without `dup` is forbidden and unrepresentable in the API: handles move as opaque
  pointers, and the compiler enforces single ownership of the token record.
- **`release`** marks the token dead and decrements `slot.refs`; at 0 the slot's value stops
  being rooted and the slot (generation +1) goes to the free list.
- **`Runtime.destroy` with live tokens (E1, amended):** nothing outlives its runtime — the
  table, the token pool, and everything they reference die with it. Using a token after
  destruction is a **host lifetime violation**; the plan does *not* claim deterministic
  detection there, because the memory that would perform the check is freed. The contract,
  explicit in E1: (a) released-token use → detected in safe builds while the runtime is
  alive (expected-panic child test); (b) destruction invalidates all tokens; (c) use after
  destruction → never dereference through a destroyed runtime (documented host bug, same
  class as using a `*Program` after `Runtime.destroy`); (d) a token passed to a *different
  live* runtime → rejected by identity/generation (expected-panic child test).
- **No scopes in M9.1 (Q4):** plain `dup`/`release` only; a scope object is additive sugar
  later.
- **Strings are handles like everything else (Q10):** immutable, so a string token exists to
  pass the string back into JS safely and to survive collections; `string(buf)` copies out
  without allocating (full length + separate wrong-kind signal).

**Temporary argument tokens (Q1).** When JS calls a host native, the engine mints tokens for
`this` and each argument and hands them to the `NativeFn`. They are owned by the engine's
*native-call record* (below), not by the native: they are released when the record tears
down — on success, on `Thrown`, on `HostError`, on any fault. A native that wants to keep a
value beyond the call must `dup` the token; `dup`'s allocation failure is checked under
`checkAllAllocationFailures` like every other crossing (E6).

**Token-pool growth is bounded and accounted (review condition).** Never freeing individual
token records buys deterministic stale detection, but a host looping create/release would
grow the pool forever while retaining no JS values at all. So:
- `Limits.max_handles` caps the pool's total records, live and dead together (free-list
  reuse keeps a churn loop at its high-water mark instead of growing it); minting beyond the
  cap is `error.LimitExceeded` with `Limit(.handles)`, catchable by the host, and the
  runtime stays usable (E6).
- The pool's and table's bytes are part of `memory()` (accounted like heap bytes, D28), so
  the embedder can see the cost.
- Test: repeated create/`dup`/release cycles drive the pool to a plateau, not unbounded
  growth; the plateau is reflected in `memory().bytes`.

## The native-call record and the guard (Q7/Q12, frozen)

When a `.call` instruction reaches a host native, the engine pushes a **native-call record**
onto the execution context: the temporary tokens, the caller VM's result slot and `pc`, and a
depth charge. The record is the *capability*:

- **Entry kinds.** The guard becomes a stack of entry kinds plus the owner thread id:
  - `host` entry — every M9.0 public entry (`resume`, `run`, `start`, `compile`,
    `collectGarbage`, `memory`, `destroy`…). Requires depth 0 and an unclaimed thread; claims
    the owner thread. At depth > 0 (same thread or not): **panic** — unchanged M9.0
    behaviour, all expected-panic tests stay green.
  - `engine` entry — pushed only by internal sites (native dispatch, and the engine-side
    implementations of the sanctioned re-entrant APIs) and only with the in-flight record as
    proof.
- **The capability cannot escape or be reused (review requirement).** The re-entry function
  takes the record reference itself; the record type is internal (never exported through
  `zqjs`), so host code cannot obtain, hold, or forge one. When the native call completes —
  any outcome — the record is consumed and popped, and with it the ability to enter at that
  depth. A stale record reference (impossible to hold publicly, impossible to reuse) fails
  the guard's stack-top check.
- **What a native may call (Q7):** `rt.call`, handle operations (`new*`/`dup`/`release`/
  readers/`throwJs`), `rt.collectGarbage`, read-only `rt.memory`. At depth > 0 on the owner
  thread these are sanctioned engine descents.
- **What a native may not call (Q7):** `compile`, `start`, `run` → **`error.Busy`** (the
  execution is unaffected; a host that wants to queue work can act on `Busy`). Everything
  else that would need a `host` entry (e.g. `Execution.resume` of the suspended outer
  execution, `defineGlobalFunction`, `Program.destroy`) → **panic**, as today (Q12: no
  exception carved out for host-driven re-entry).
- **Cross-thread:** panics always.
- `destroy` claims the guard as today; while poisoned, no callback starts and no token is
  minted (E7).

## Step budgets, slices, and overshoot (Q8, frozen)

- One cumulative budget per top-level entry, shared by the whole chain (the execution
  context, above). A nested call charges it; it never resets.
- A `resume(steps)` slice is a **promise about when the host regains control**, not a hard
  stop. A synchronous native callback cannot suspend mid-callback (its C call stack is
  active), so a native chain may **overshoot the slice**: the host regains control when the
  chain completes and the VM next reaches a step boundary. This is frozen semantics,
  documented in EMBEDDING.md and proven by an explicit test (below).
- The hard stop is the cumulative `max_steps`, enforced by `rt.step()` at every instruction
  of every VM in the chain; the counter never exceeds it (E4's no-overflow property).
- **The boundary check (review-frozen):** when a native-call record tears down, the engine
  checks the latched budget fault *before* reading the native's outcome — a latched
  `LimitExceeded` faults the outer execution even if the native returned success. The host
  callback cannot be forcibly interrupted (its C call stack is active), but it cannot convert
  a budget failure into a result.
- `rt.call` from the host at depth 0 runs to completion under a fresh context's budget;
  no `steps` parameter in M9.1 (slicing is additive later, Q8).
- While a native chain is in flight, the outer execution's slice bookkeeping simply waits:
  overshoot is absorbed when control returns (the lifecycle diagram, S11, shows exactly
  where).

## Native errors (Q5, frozen)

| outcome | meaning | poison? |
|---|---|---|
| `Thrown` (+ `rt.throwJs` first) | the native deliberately threw a JS exception; a JS-visible event (E5) | no |
| `HostError` (+ `out.host_message`) | a host operation failed (a database lookup, a missing game resource); the execution faults with a host classification + the native's message through the E10 text rules; the embedder gets a proper error boundary without a misleading JS exception | no |
| `LimitExceeded`, `Unsupported`, `OutOfMemory` | as in M9.0: the execution faults, the runtime stays usable (E6) | no |
| `Internal` | a host bug; the poison belt catches it | **yes** (E7) |

Returning `Thrown` without a pending throw, or `HostError` without `host_message`, is a host
bug — checked like the other host bugs. A host failure is never modelled as a `RangeError`
throw (that was revision 1's recommendation, overturned in review).

## D35, D36, and the other decisions M9.1 touches

- **D35 (precision), third revision:** a `.call` to a host native spans the steps of
  whatever runs inside it (nested VMs under model B) and is precise at its own boundary: if
  the native call faults or throws, the caller VM's operand state is exactly as before the
  call (the M7 comment in `vm.zig` — "If it fails, nothing has been popped" — stays true;
  under model B nothing was popped yet anyway).
- **D36 (transactional calls):** untouched — under model B no native frame enters the VM's
  frame stack, which is precisely the point of choosing B.
- **D40:** stands (Q9); `user_conversion` remains the error.
- **E1 (ownership):** amended with the handle rules above (tokens die with the runtime;
  detection only while it is alive; cross-runtime rejection).
- **E2 (guard):** entry-kind stack as above; all M9.0 panic behaviours preserved.
- **E4 (budget):** the shared execution context is E4's counter made explicit; no semantic
  change for non-embedding runs.
- **E5/E6/E7:** unchanged meanings; `HostError` slots into E6's "faults the execution,
  runtime stays usable" row.
- **GC_DESIGN §4:** "Host handles (M9)" becomes the handle table — one root set, traced with
  the VM registrations.

## The lifecycle (the review's gate for P1)

One thread, one runtime `R`, program `P` compiled, execution `E` suspended mid-run. `f` is a
script function containing `n1(...)`; `g` is a script function containing `n2(...)`; `n1`
and `n2` are host natives registered via `defineGlobalFunction` (`ctx_b`, `ctx_b'` are host
memory, borrowed by `R` until destroy). The host holds token `H_g` → the function `g`.

```
S0  Host thread, before the call.
      guard: depth 0, no owner       active VM: none running
      exec context: none
      roots: realm + protos · E's suspended VM V1 (registered for E's lifetime, M9.0)
      tokens: H_g (host-owned) · ctx_b, ctx_b' (host memory, borrowed by R)

    Host ── Execution.resume(E, steps = 10) ──────────────────────────────────

S1    guard: [host] (owner = this thread)        active VM: V1
      exec context X created: budget { max = limits.max_steps, used = E.used },
        call_depth 0, re-entry stack, active-VM root list (V1 already in it)

S2    JS f runs on V1; every instruction charges X.budget via rt.step().
      Slice promise: the host regains control after ≤ 10 more steps —
      unless a native callback is in flight (S11: the frozen overshoot rule).

S3    f executes `.call n1` (host native).
      V1 SUSPENDS mid-instruction (callee + args on its operand stack; V1 stays
        root-registered for the whole descent — nothing mutates its stacks).
      Engine pushes native-call record N1 on X:
        mints temp tokens T_this, T_a0 … T_an (slot refs +1 → the table roots them)
        records V1's result slot + caller pc; depth charge (limits.max_call_depth)
      guard: [host, engine·N1]      ← engine entry, only internal sites can push
      n1(rt, ctx_b, this = T_this, args = [T_a0 …], out)

S4    n1 calls rt.call(rt, H_g, …)               ← the sanctioned re-entry (Q7)
      guard: [host, engine·N1] (rt.call at depth > 0 on the owner thread is engine
        descent; any OTHER public API here panics — Q12)
      nested VM V2 created (shares heap + realm); registered in X's root list
      X.call_depth + 1 (limits.max_call_depth across the whole chain)
      budget: NO fresh budget — V2 charges X.budget, the shared cumulative one
      H_g's slot supplies the callee; the token itself is untouched (still host-owned)

S5    JS g runs on V2, charging X.budget — the same counter f charged.

S6    g executes `.call n2` (host native). V2 SUSPENDS mid-instruction (stays
      registered). Engine pushes record N2; mints T'_this, T'_a0 …; depth charge.
      guard: [host, engine·N1, engine·N2]
      n2(rt, ctx_b', this = T'_this, args = [T'_a0 …], out)

S7    n2 calls rt.collectGarbage()               ← THE GC POINT (R2's crux)
      stop-the-world, same thread (the guard proves exclusivity). Roots traced:
        realm + protos · exception message · X's active-VM registrations
          [V1 suspended mid-instruction, V2 suspended mid-instruction]
        · handle-table slots with refs > 0 (N1's T_this/T_a…, N2's T'_…,
          H_g, every host token) · joining asserted empty
      n1's argument values survive BECAUSE THE TABLE ROOTS THEM — not because
        V1's stack happens to still hold them. That is the R2 guarantee.
      Sweep frees only unreachable objects; both suspended VMs and all live
      slots are untouched. R stays unpoisoned.

S8    n2 returns success (out.result = a token it minted, or null → undefined).
      Engine tears down N2: copies the result into V2's operand slot (V2 is a
        root), releases N2's tokens (T'_this, T'_a…, and the result token after
        the copy); call_depth −1; guard pops engine·N2 — its capability is
        consumed and cannot be reused (Q12's scoping requirement).
      V2 resumes g.

S9    g returns → rt.call completes.
      Result minted as token T_r (refs +1); ownership → the caller (n1).
      V2 deregistered and torn down; call_depth −1.
      Error paths: Thrown → n1 sees error.Thrown + the pending exception;
        LimitExceeded (X.budget exhausted) → LATCHED in X: n1 may finish its
        callback but cannot clear or replace the latch, and the outer
        execution faults with it at the native boundary (S10) regardless of
        n1's return value — a budget fault cannot be laundered.

S10   n1 returns.
      Engine tears down N1: FIRST the latched-budget check (a latched
        LimitExceeded faults the outer execution now, whatever n1 returned);
        then, if out.result is set, its value is copied into V1's operand slot
        (V1 is a root), then ALL of N1's tokens are released (T_this, T_a…,
        and T_r if n1 did not release it) — on EVERY outcome: success, Thrown,
        HostError, any fault. The exceptional path leaks nothing.
      Release-order invariant (review-frozen): a temporary token stays a GC
        root until its destination is safely written. If writing to V1's
        operand slot can trigger an allocation (stack growth) or a collection,
        T_r remains live across that operation — it is released only after
        the destination has become a root.
      call_depth −1; guard pops engine·N1; V1 resumes f.

S11   f continues on V1; rt.step() still charges X.budget (nested consumption
      included). Slice accounting: the native chain may have consumed far more
      than the remaining slice — the frozen overshoot rule (Q8): the slice is a
      promise about when the host regains control, not a hard stop mid-native
      (a C call stack cannot suspend); the cumulative max_steps is the hard
      stop, enforced by rt.step() at every instruction of every VM in the chain.

S12   resume returns to the host.
      guard pops host (depth 0, owner released); X.budget saved → E.used
        (E4: cumulative over E's resumes); X torn down or kept per E's status.
      Host still owns H_g and any tokens it minted; every temp token is gone.
```

The same state, as a table (the four things the review asked the diagram to show):

| point | guard stack | active VM | step counter owner | roots registered | who owns every handle |
|---|---|---|---|---|---|
| S0 | empty | none | none | realm, protos, V1 (E alive) | host: H_g; host memory: ctx_b, ctx_b' |
| S1–S2 | [host] | V1 | X (budget = E.used) | realm, protos, V1 | host: H_g |
| S3 | [host, engine·N1] | V1 *suspended*, native n1 running | X | realm, protos, V1, **table slots (T_this, T_a…)** | host: H_g · engine (N1): T_this, T_a… |
| S4–S5 | [host, engine·N1] | V2 (V1 suspended) | X (shared, no fresh budget) | realm, protos, **V1, V2**, table slots | host: H_g · engine (N1): T_this, T_a… |
| S6 | [host, engine·N1, engine·N2] | V2 *suspended*, native n2 running | X | as above + N2's slots | host: H_g · engine (N1): T_this, T_a… · engine (N2): T'_this, T'_a… |
| S7 (GC) | [host, engine·N1, engine·N2] | both suspended | X | realm, protos, V1, V2, all refs>0 slots | unchanged — this is the point of R2 |
| S8 | [host, engine·N1] | V2 (g resumes) | X | V2's slots gone | N2's temp tokens released; result copied into V2 |
| S9 | [host, engine·N1] | V2 finishing → none | X | V2 deregistered | engine (N1): T_this, T_a…, **T_r (rt.call's result)** |
| S10 | [host] | V1 (f resumes) | X | V1 only | N1's tokens released (incl. T_r, after copy) |
| S11–S12 | empty | none running | E (X.budget → E.used) | realm, protos, V1 (E alive) | host: H_g (+ whatever it kept) |

Consistency checks the diagram pins (each becomes an assertion or a test):
- At every instant, at most one VM is *actively stepping*, and it is always the innermost —
  the guard's stack top names it.
- Exactly one budget exists per chain, and it is charged from S2 to S11 regardless of which
  VM executes — the overshoot test reads this counter.
- A suspended VM is never deregistered before its native returns — the R2 test proves a
  collection between S4 and S9 cannot free what V1 or the table holds.
- Temp tokens exist exactly between a record's push (S3/S6) and its teardown (S10/S8) — the
  leak checks run at both teardowns, on every outcome.
- Release order: a temp token is released only after its destination has been written and
  become a root — including across any allocation the write itself may trigger (the
  gc-stress build turns that window into a test).

## Acceptance criteria (all under plain, `-Dgc-stress`, `-Dstack-stress`, ReleaseSafe)

- **R1, the core:** a host native calls a JS function that allocates and grows the stack
  (deep recursion, closures created before and called after the move) — under
  `-Dstack-stress` — and the native still reads every argument exactly. node-equal outputs.
- **R2, the GC-stress chain (named test):** exactly the reviewed chain — a native receives
  argument tokens, calls back into JS which allocates heavily, a collection runs (gc-stress
  forces one at every safepoint), the native resumes and uses its tokens: every value
  intact; `memory().bytes` before/after proves the original objects were rooted by the
  table, not by luck.
- **Slice overshoot (named test, Q8):** `resume(steps: 1)` on a script whose first
  instruction calls a host native that `rt.call`s a long-running JS loop: the host regains
  control only after the whole chain completes (charged steps ≫ slice); a nested runaway
  loop hits `max_steps` exactly (`LimitExceeded`), the counter never exceeds it, the latch
  is set, and — even when the native returns success — **the outer execution faults at the
  native boundary** with the latched `LimitExceeded`
- **Handles:**
  - mint/`dup`/`release`, leak-checked; a released token's use is caught — expected-panic
    child test (deterministic, safe builds, runtime alive);
  - **token-pool churn:** repeated create/`dup`/release cycles plateau at the pool's
    high-water mark (free-list reuse), reflected in `memory().bytes`; minting past
    `Limits.max_handles` is `LimitExceeded(handles)`, catchable, the runtime stays usable;
  - a token survives collections taken by *other* executions (gc-stress throughout);
  - a token to a value that becomes garbage *while held* stays alive; releasing it lets the
    next collection free it (`memory().bytes` before/after);
  - `Runtime.destroy` with live tokens frees everything (leak check); use-after-destroy is
    a documented host lifetime violation (no expected-panic test — the checking memory is
    gone; E1 states this);
  - a token passed to a different live runtime → expected-panic child test;
  - `checkAllAllocationFailures` over mint/copy/read/release; the runtime stays usable (E6).
- **Natives from JS:**
  - a global function defined by the host, called by scripts, `this`-correct (D41), arity
    variants, node-equal output alongside the built-ins;
  - duplicate registration rejected — including built-in names — realm unchanged
    (`error.NameTaken`);
  - throws via `rt.throwJs` surface as ordinary `Uncaught TypeError: …` (E5/E6, E10 text
    rules); `Thrown` without a throw, and `HostError` without a message, are host bugs
    (checked);
  - `error.HostError` faults the execution with the native's message and a host
    classification; the runtime is **not** poisoned and a subsequent run works;
  - `error.OutOfMemory` from a native faults that execution only; the runtime stays usable;
  - re-entrancy: native → JS → native → JS, three levels deep, output exact, one shared
    depth counter, one shared budget;
  - `compile`/`start`/`run` from inside a native → `error.Busy`, execution unaffected;
  - other public API from inside a native (e.g. `resume` of the outer execution) → panic
    (the M9.0 expected-panic tests stay green unchanged);
  - a native calling back while the runtime is poisoned gets `Internal` (E7).
- **Host → JS (`rt.call`):**
  - call a script function with tokens in, token out; numbers/strings round-trip bit for
    bit (numbers through f64; strings through UTF-16, E10's surrogate rules;
    `string(buf)` truncation reported by the full length);
  - a script exception becomes `error.Thrown` + `Failure` on the host's call;
  - the shared budget bounds it (a runaway function hits `max_steps`);
  - `rt.call` while an execution is *suspended* works (fresh context, shared realm);
    mid-callback it is the guard's business (Q7).
- **Realm changes persist across runs (E3, documented):** a `defineGlobalFunction` made
  after run 1 is visible to run 2 and to executions of other programs; `ctx` is borrowed
  until `Runtime.destroy`.
- **Snapshot test:** every new public declaration is a reviewed addition to the approved
  list (D46) — `Handle`'s methods, `call`, `defineGlobalFunction`, the `new*` constructors,
  `throwJs`, `NativeFn`/`NativeOut`/`NativeError`, `error.Busy`, `error.NameTaken`,
  `error.HostError`.
- **The oracle:** treewalk untouched; a program using host natives is VM-only (documented
  in EMBEDDING.md).

## Not in M9.1

- **Host objects with property accessors** (JS-side getter/setter into host data): exotic
  object plumbing in `object.zig`; a later milestone.
- **Slicing a host-initiated call** (suspending/resuming `rt.call` across host frames):
  additive later, Q8.
- **Model A** (nested native frames on one VM): a future optimization, gated on a
  feasibility prototype that measures nested-VM cost (Q11).
- **D40 revision** (user `valueOf`/`toString`): stays out (Q9).
- **Scopes** for batch-releasing tokens: additive sugar later (Q4).
- **Classes, `new`, promises, modules:** unchanged from ROADMAP ("deliberately not yet").
- **The C ABI (M9.2):** token indices and the guard's model are chosen to make it thin, but
  it is designed separately.
- **Multiple threads per runtime:** still not planned (ROADMAP).

## Design-decision records to write (P1's deliverable once approved)

- **D50** — handles: table + reference-counted slots + generation-checked tokens; the token
  pool's bounded, accounted growth (`Limits.max_handles`, bytes in `memory()`); the E1
  amendment (detection only while the runtime is alive; cross-runtime rejection); the
  release-order invariant (a temp token stays a root until its destination is written,
  across any allocation the write may trigger).
- **D51** — the shared execution context: one cumulative budget, one logical depth counter,
  re-entry state, active-VM root registrations; model B; the slice-overshoot rule, the
  latched budget fault, and the boundary check (Q8/Q11).
- **D52** — the guard's entry-kind stack and the callback-scoped capability; the sanctioned
  re-entrant API and `Busy` (Q7/Q12).
- **D53** — host natives: `defineGlobalFunction` (duplicate rejection, `ctx` lifetime),
  temporary argument tokens, the `NativeFn` contract, `HostError` (Q1/Q5/Q6).
- **D54** — D40 stands (Q9); string handles and `string(buf)` semantics (Q10).

## Phases

- **P1 — this document approved.** The decisions above are frozen; D50–D54 written; the
  lifecycle diagram is the internal-consistency gate. **No implementation before approval.**
- **P2 — handles.** Table, token pool, mint/`dup`/release/readers, root set, the leak and
  expected-panic tests.
- **P3 — the shared execution context and the guard.** Entry kinds, the capability, root
  registrations, the shared budget/depth counters; `rt.call` on top (model B machinery —
  needed regardless).
- **P4 — host natives from JS.** `defineGlobalFunction`, native-call records, temp tokens,
  the error contract (`HostError`, `Busy`), R1's core test.
- **P5 — proof.** R2, the overshoot test, the full acceptance list, `examples/` extended
  (a native + a callback), EMBEDDING.md, ROADMAP, DESIGN_DECISIONS, the snapshot test's new
  approved names.
