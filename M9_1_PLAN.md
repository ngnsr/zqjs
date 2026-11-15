# M9.1 plan: values, natives and handles across the boundary

Status: **draft for review (revision 1).** Nothing here is settled; the questions at the end
need decisions before any M9.1 code is written. M9.0 (tagged, in `main`) defined the shape the
API must grow in; this plan must not contradict it without revising it.

Scope, from ROADMAP.md (M9.1):
- values crossing the boundary in both directions;
- native functions callable from JavaScript;
- JavaScript functions callable from the host;
- GC-safe handles with explicit ownership;
- re-entrant execution semantics.

The C ABI stays M9.2 (it is a thin layer on whatever this plan settles).

## The one requirement this plan is organized around

**R1 (review requirement): a native function must be able to call back into JavaScript
without invalidating VM state.**

That single sentence touches five separate facts of today's engine, and the plan treats each:

| fact (today's code) | what re-entrancy forces |
|---|---|
| `Native.call` *borrows* its argument slice: `n.call(rt, this, vm.stack[args..vm.sp])` (value.zig, D12/D40 comment). The comment says "it cannot call back into JS, so the stack cannot move under it". | The arguments must be **stable** for the whole call: a nested JS call grows (and may realloc) the operand stack. D12's `NativeCtx.arg(i)` idea exists exactly for this and was postponed in M7 (D40). |
| A native is called *mid-instruction*: `.call` reads the callee, calls the native, writes the result and sets `pc` after. D35's precision contract covers one instruction = one step. | A nested JS call makes the outer instruction span **many steps**. The precision contract needs a third outcome, or the model changes. |
| `Runtime.engine_roots` is **one optional slot** holding the running VM's roots (runtime.zig). | Either there are still never two VMs alive at once (nested-frame model), or the slot becomes a list (separate-VM model). |
| The entry guard (E2) panics on *any* overlap, same thread included. An output writer that re-enters panics — a tested behaviour. | Re-entry from a native is not overlap: it is the same thread, going deeper. The guard must distinguish **engine-driven descent** (legal) from host-driven overlap and cross-thread use (bugs). |
| `Value.string/.object/.closure` are pointers into the heap; the collector may free them. M9.0 deliberately kept values inside the engine (not in M9.0). | Any value the host holds across a call or a collection must be a **handle**, not a `Value` copy. GC_DESIGN §4 already reserves "Host handles (M9): registered and released explicitly". |

Also true today, and unchanged by this plan unless a question below revises it:
- `Native` has **no context field** (value.zig): a native is a static struct `{ name, call,
  namespace }`. Host natives that carry host state need somewhere to put it.
- `get_global` reads only the built-in realm (builtins.zig); scripts cannot create globals
  (E48: assigning an undeclared name is `Unsupported(global_assignment)`), so **host globals
  need a home** in the realm or the compiler.
- Conversions never call user functions: a `valueOf`/`toString` that isn't the built-in native
  is `Unsupported(user_conversion)` (D40). Re-entrancy makes that restriction *removable*;
  whether M9.1 removes it is a scope question (Q9).
- `max_call_depth` counts `frames.items.len` inside one VM. Cross-execution depth (if the
  separate-VM model wins) needs shared accounting.
- The tree-walker is the oracle and is **not** part of M9.1: it stays behind `--engine=
  treewalk`, as in M9.0. Host natives run on the VM only.
- A poisoned runtime (E7/D49) must reject every new crossing too: no native callback starts,
  no handle is minted, `compile`/`start`/`run` already return `Internal`.

## The three API surfaces (sketches; names and shapes open for review)

All new public declarations go into `zqjs` and are added to the snapshot test's approved list
(D46: each one is a reviewed decision). `Handle` is the new opaque type — the M9.0 types are
untouched except where a question below says otherwise.

```zig
pub const Handle = opaque {      // a GC-safe reference to one JS value
    pub fn kind(h: *const Handle) Kind;        // undefined, null, boolean, number,
                                               // string, function, object, array
    // Reading leaf values copies, under the guard; never allocates (Q10):
    pub fn number(h: *const Handle) ?f64;
    pub fn boolean(h: *const Handle) ?bool;
    /// Copies the string's UTF-16 units into `buf`; returns the full length
    /// (so a too-small `buf` is a truncation, not a loss).
    pub fn string(h: *const Handle, buf: []u16) error{OutOfMemory}!?usize;

    // Handles to heap values:
    pub fn retain(h: *Handle) *Handle;         // +1 reference (Q3/Q4)
    pub fn release(h: *Handle) void;           // -1; frees when zero
    /// Same value as `h`, new independent handle (Q4: handles are cheap to copy).
    pub fn dup(h: *const Handle) error{OutOfMemory}!*Handle;
};

pub const Runtime = opaque {
    // ... M9.0 declarations unchanged, plus:

    /// Host → JS. Calls `f` with `this` and the arguments, runs it to completion
    /// within the runtime's limits (Q8: slices?), returns the result as a handle.
    pub fn call(rt: *Runtime, f: *Handle, this: ?*Handle, args: []const *Handle,
                failure: ?*Failure) (RunError || StartError)!*Handle;

    /// JS → host. Registers a host native as a global under `name` (Q6: its home).
    /// `ctx` is passed back on every call; it is the host's, never touched by ZQJS.
    pub fn defineGlobalFunction(rt: *Runtime, name: []const u8,
                                native: *const NativeFn, ctx: ?*anyopaque) error{OutOfMemory}!void;
};

/// A host native. Runs with the entry guard held at depth ≥ 1 (R1, E2 revised):
/// it may call back into JS through `rt` (Q7: what else it may do).
pub const NativeFn = fn (rt: *Runtime, ctx: ?*anyopaque, this: ?*Handle,
                         args: []const *Handle, result: ?*Handle,
                         failure: ?*Failure) NativeError;

pub const NativeError = error{ Thrown, LimitExceeded, Unsupported, OutOfMemory, OutputFailed, Internal };
// A native throws a JS exception with `rt.throwJs(kind, message)`; returning
// error.Thrown without one is a host bug (checked). Everything else keeps M9.0's
// meaning (E5/E6): Thrown is a JS-visible event, the rest fault the execution.
```

Host values into JS:
- Leaf values need no handle: `Options`-level constructors on `Runtime`
  (`rt.newNumber(f64)`, `rt.newStringUtf16([]const u16)`) return handles, since even a number
  result must survive the caller's next collection once it is an argument.
- Host *objects* (JS sees a black box with identity) are **not in M9.1**; see *Not in M9.1*.

## R1's alternatives, with trade-offs

These are alternatives for the *engine-internal* re-entrancy mechanism. The public API above
is largely indifferent to which wins, which is the point: settle the semantics first.

### A. Same VM, nested frames; arguments copied to a stable buffer

A host native's call is recorded, its arguments **copied** into a runtime-owned buffer that
the collector roots (or into handles — Q1 decides), and the callee runs as ordinary new frames
on the *same* VM. When it returns, the VM writes the result into the caller's operand slot and
completes the native instruction.

- *What it needs:* a "native call" record in the frame stack (a new frame kind: `{ kind =
  .native, native, ctx, this, copied_args, result_slot, caller_pc }`); `enter` grows it like a
  closure frame, so `max_call_depth` and `max_stack_slots` are charged once, everywhere, for
  free. D35 gains: "a `.call` to a host native may execute many steps — its callee's — and is
  precise at its own boundary: if the native faults, the caller's state is exactly as before
  the call". The borrowed slice disappears: `Native.call` receives stable storage (D12's
  `NativeCtx`, which the M6 design already sketched and D40 postponed).
- *Trade-offs:* touches the VM's heart (frames, D36 transactional calls, `-Dstack-stress`
  which moves the stacks on every entry — copied args must not be in the stack, or the stress
  mode breaks them). Argument copying costs one allocation per host-native call (hoisted into
  the existing call path; measured before it ships). Exception unwinding through a native
  frame must free/release its argument handles.
- *What it buys:* one GC story (one VM's roots), one depth counter, semantics that match JS
  exactly (the callee is a real frame: `new.target`-free recursion, `this`, arguments objects
  — none exist yet, but nothing blocks them later), and the C ABI gets the natural shape.

### B. Separate execution per native callback

The outer VM is **suspended** while the host native runs — its stacks cannot move, because
nothing mutates them — so the borrowed argument slice stays valid as-is. The nested JS call
runs on a fresh `Vm` sharing the runtime's heap and realm (what `rt.call` does anyway for a
host-initiated call). The native translates the inner call's outcome into its own result.

- *What it needs:* almost no VM surgery: `engine_roots` becomes a list (M9.0's `extra_roots`
  pattern, E5), depth is accounted across the two VMs (one shared counter on `Runtime`), and
  `rt.call` and the native path share one implementation. Guard: same-thread depth counter.
- *Trade-offs:* the nested call is *not* a frame of the outer call: recursion depth
  accounting is hand-rolled (two counters to keep in step); a deep native→JS→native chain
  costs a whole VM per level (memory, and per-level init cost); semantics diverge from JS in
  ways tests must pin (e.g. the outer call's `arguments`-like state, if ever added, is
  invisible mid-native). But for the M9.1 features themselves — `rt.call` from the host, a
  native that queries the realm — B is *exactly* the same machinery, so it must be built
  regardless.
- *Note:* B is also the **fallback**, exactly as M9.0 planned a fallback for E5: if A's VM
  surgery proves riskier than the review likes, ship the API on B (nothing public changes)
  and fold A in later as a purely internal improvement.

### C. Never-moving stack storage

Restructure the operand stack so frames never move: per-frame segments (a linked list of
fixed chunks), or an arena of frame regions addressed stably.

- *Trade-offs:* the biggest change of the three — it rewrites `reserve`, `stack_end`,
  `enter`/`return`, the `-Dstack-stress` contract (which exists precisely to catch stale
  indices), and the verifier's `max_stack` reasoning. It makes *all* borrows permanently
  safe, but it is a VM redesign bought for a problem A solves with one buffer.
- *Verdict for M9.1:* deferred, recorded as the long-term answer if A's copying shows up in
  profiles (M10's VM-performance milestone is the natural place to revisit).

**Provisional recommendation: A**, with B already built for `rt.call` (they share the
"run a closure on a VM" core). Presenting both to the review is the point of this plan; the
recommendation may be overturned.

## Handles

### Representation (Q2)

| | (i) handle table in the runtime | (ii) heap "pin" object per handle | (iii) explicit pin/unpin of raw Values |
|---|---|---|---|
| idea | `Runtime` owns a growable table of `?Value` slots; a handle is an index + epoch | every handle is itself a small heap object the collector marks | the host marks values on the runtime, unpins later |
| stale use | caught by the epoch (cheap compare), deterministic | caught by the object's liveness only under gc-stress | not caught at all |
| cost | one table slot per live handle; free list | one allocation per handle | none |
| fits the collector | yes: the table is one root set (E5's pattern) | yes: they are ordinary objects | yes, but the burden is on the host |
| C ABI (M9.2) | integer handles, trivial | pointer handles, trivial | integer tokens |
| risk | table growth during a call (transactional) | more heap objects, more allocation-failure paths | every host mistake is a use-after-free |

Provisional recommendation: **(i)** — one root set, deterministic stale detection, cheap
copies. A handle being just an index is also why Q4 (copying) is easy.

### Lifetime and ownership (Q3/Q4)

The questions the review must answer, with the options each could take:

- **Can handles be copied?** Under (i): yes — a handle is an index; `dup` mints a second
  reference. Copies of the *index* without a new reference would alias lifetimes (two owners,
  one slot) — forbidden; the epoch check makes a released one stale, but two live indices to
  one slot break release accounting. So: copying is by `dup`, never by copying the pointer.
- **Reference-counted?** Under (i): the *slot* is live until its last handle is released.
  A per-slot count (one per `dup`/`retain`) makes release idempotent-safe and matches how
  executions reference-count programs (E1). Alternative: no counting — a handle is valid
  until the host releases *that* handle, and any second handle to the same value is the
  host's bookkeeping error. The count is the safer default; it is one usize per slot.
- **What happens when `Runtime.destroy` runs with handles alive?** The same rule as programs
  and executions (E1): nothing outlives its runtime — every handle dies with it, the host's
  remaining handles become invalid, safe builds catch their use with a tag check. Documented
  as a host bug, exactly like using a `*Program` after `Runtime.destroy`.
- **Scope vs free-for-all:** should there be an explicit scope object ("all handles minted
  inside are released together")? It maps well onto a host frame (game: one scope per
  callback), and it makes leaks structural. Alternative: plain retain/release only, scopes
  can be added later as sugar. *Recommendation:* plain retain/release in M9.1; a scope is
  additive later.
- **Strings:** a string handle can be read out (`string(buf)`); whether strings need handles
  at all (a copy-out function on `rt` could take an index) is Q10 — strings are immutable, so
  a handle to one is only a GC-safety device for *passing it back into* JS.

### Where host globals live (Q6)

Scripts cannot create globals (E48) and `get_global` reads the built-in realm only.
Alternatives:

1. **Compile-time injection:** `Options.globals: []const GlobalDef` — name + a value
   (number/string/native). Immutable, checked at compile (no redefinition), the cleanest
   match to "ZQJS has no writable globals". Costs: `compile` grows a parameter; the resolver
   must know the names (they become `get_global`s today).
2. **A realm extension API:** `rt.defineGlobalFunction(...)` adds to the realm at runtime;
   scripts read it like any built-in. Mutable by the host across runs (E3 documents shared
   realm state already: "a script that changes `Object.prototype` changes it for later runs").
   Costs: realm state becomes host-mutable, and the compiler cannot see the names (fine —
   `get_global` already resolves at run time through `builtins.global`).
3. **Both:** constants at compile time, functions at run time.

*Recommendation:* **2** — one mechanism, matches how the built-in realm already works
(`Native` with a `namespace`), keeps `compile`'s signature stable from M9.0. But it makes
`defineGlobalFunction` a *mutation of the realm*, so it is forbidden while any execution is
suspended or faulted? No — E3 says realm changes persist; the rule proposed is: allowed
anytime the guard is held and the runtime is not poisoned; a later compile sees it (Q6 asks
the review to confirm).

### Native errors (Q5)

Today a native returns `Error!Value` and can `rt.throw(...)` a JS exception before returning
`error.Thrown`; `Unsupported`/`LimitExceeded`/`OutOfMemory`/`Internal`/`WriteFailed` come out
of shared helpers. The host-native surface must keep that distinction, because it is the
whole point (E5: "Only Thrown is a JavaScript-visible event"):

- **Throwing:** `rt.throwJs(name: ErrorName, message: []const u16)` (UTF-16, like script
  exceptions; converted through the E10 rules for the `Failure` text). Returning
  `error.Thrown` without having thrown is a host bug — checked like the other host bugs.
- **Host failures vs engine failures:** the existing `Error` set already separates them:
  `OutOfMemory` is the host allocator, `WriteFailed` is the host writer, `Internal` poisons
  (a ZQJS bug — a native must never set it; the poison belt catches one anyway),
  `LimitExceeded`/`Unsupported` are the engine's resource/feature limits. A native's `ctx`
  failures that are neither JS exceptions nor resource failures should be modelled as…
  what? Options: (a) a host "abort" — `error.Thrown` with a `RangeError`, works today, no
  new machinery; (b) a new `error.HostError` that faults the execution with a host-provided
  failure kind. *Recommendation:* (a) for M9.1 — no new error kind; the `Failure` already
  carries a host-facing message, and M9.2's C ABI can layer its own kinds on top.
- **Precision:** a native that throws must leave the caller's operand state untouched —
  this is already true (the M7 comment in vm.zig: "If it fails, nothing has been popped"),
  and under A it stays true because the native frame is a real frame the unwinding pops.
- **Allocation failure at every boundary crossing** (ROADMAP's M9.1 list): minting handles,
  copying args, unwinding — all under `checkAllAllocationFailures`, as in M9.0 (E6: the
  runtime stays usable).

## The guard, revised (E2)

Proposed change, keeping every M9.0 behaviour:

- The guard becomes **owner thread id + depth counter** (both in the runtime, atomic).
- Entry when depth == 0: claim (thread, depth 1). Entry when depth > 0: legal only for the
  same thread **through the native/`rt.call` path** — the engine's own descent; other paths
  (the host API) panic as today, even on the same thread, so "a call from inside the host's
  own output writer" still panics (the M9.0 expected-panic tests stay green unchanged).
- Cross-thread: panics always.
- Exit decrements; destroy claims the guard as today.

What a native may call back into (Q7): `rt.call` (JS), the handle constructors/readers,
`rt.collectGarbage`? A collection during a native call is safe *only* in model A/B where the
native's live values are rooted (args are handles). Throwing (`rt.throwJs`). Everything that
would *start* another execution (`start`, `run`, `compile`) is proposed **forbidden while a
call is active** — not a panic but `error.Busy`? or panic? (Q7 presents both; panic matches
E2's style, `Busy` is kinder to hosts that legitimately want to queue work).

## Step budgets, limits, poisoning

- A nested or host-initiated call charges **one** `max_steps` counter: the *execution* it
  belongs to (model A: the outer execution; `rt.call` from the host: its own fresh counter —
  M9.0's E4 said "per execution"; the host call is its own execution-like context, and Q8
  asks whether `rt.call` gets a `steps` slice parameter or runs to `limits.max_steps`).
- `max_call_depth` and `max_stack_slots` are shared counters on the runtime (in model B they
  must be; in A they come free from the frame stack).
- A native faulting the execution with anything but `Thrown` faults it as E6 says; `Internal`
  poisons (the belt already in `resumeImpl` covers nested stepping, since model A's nested
  calls are steps of the same execution).
- While poisoned: no native callback, no `rt.call`, no handle minted, `compile`/`start`/
  `run` return `Internal` (M9.0 behaviour, unchanged); destroy paths stay available.

## Internal changes (all hidden behind `zqjs`)

1. **Frames:** a native-call frame kind (model A) or a cross-VM depth counter (model B).
2. **`engine_roots`:** stays single in A; becomes a list in B (the `extra_roots` pattern).
3. **Handle table:** runtime-owned slots + epoch + free list, one root set, registered like
   E5's programs/executions.
4. **`Native` grows a context** (a `?*anyopaque` and an owner for cleanup) — or host natives
   are `Value.object`-like heap records; Q1's copy decision interacts here (args as handles
   make the native frame independent of stack layout).
5. **Realm:** `defineGlobalFunction` adds to the realm's namespace maps; `builtins.global`
   resolves host names first.
6. **The CLI:** default path unchanged; a `--` test hook only if the tests need one.
7. **GC_DESIGN §4:** the "Host handles (M9)" line becomes real: the table is a root set.
8. **D35 revised (third time):** the native-frame step semantics; D36 revised: what a
   transactional call means when the callee is a host native.

## Acceptance criteria (all under plain, `-Dgc-stress`, `-Dstack-stress`, ReleaseSafe)

- **R1, the core:** a host native calls a JS function that allocates and grows the stack
  (deep recursion, closures created before and called after the move) — under
  `-Dstack-stress` — and the native still reads every argument exactly. node-equal outputs.
- **Handles:**
  - create/dup/release, leak-checked; a released handle's use is caught (epoch) — an
    expected-panic child test, as in M9.0;
  - a handle survives collections taken by *other* executions (gc-stress throughout);
  - `Runtime.destroy` with live handles frees them all; later use panics (tag/epoch);
  - a handle to a value that becomes garbage *while held* stays alive (that is the point);
    releasing it lets the next collection free it (`memory().bytes` before/after);
  - `checkAllAllocationFailures` over mint/copy/read/release; the runtime stays usable (E6).
- **Natives from JS:**
  - a global function defined by the host, called by scripts, `this`-correct (D41), arity
    variants, and node-equal output alongside the built-ins;
  - throws via `rt.throwJs` surface as ordinary `Uncaught TypeError: …` (E5/E6, the same
    `Failure` rules as any script error, E10 text rules);
  - `error.OutOfMemory` from a native faults that execution only; the runtime stays usable;
  - re-entrancy: native → JS → native → JS, three levels deep, output exact, depths
    accounted, one `max_steps` counter across the whole chain (a runaway inner script hits
    the cap exactly as a plain script would);
  - a native calling back while the runtime is poisoned gets `Internal` (E7).
- **Host → JS (`rt.call`):**
  - call a script function with handles in, handle out; numbers/strings round-trip bit for
    bit (numbers through f64; strings through UTF-16, E10's surrogate rules);
  - a script exception becomes `error.Thrown` + `Failure` on the host's call;
  - step cap honoured (Q8's slice-or-not decision shows up here);
  - `rt.call` while an execution is *suspended* works (separate context, shared realm);
    mid-*call* it is the guard's business (Q7).
- **Realm changes persist across runs (E3, documented):** a `defineGlobalFunction` made
  after run 1 is visible to run 2; visible to executions of other programs.
- **Snapshot test:** every new public declaration is a reviewed addition to the approved list.
- **The oracle:** treewalk untouched; a program using host natives is VM-only (documented in
  EMBEDDING.md).

## Not in M9.1

- **Host objects with property accessors** (JS-side getter/setter into host data): needs
  exotic-object plumbing in `object.zig`; an embedder can go far with plain objects the
  native fills in. A later milestone.
- **Calling JS with a suspended-then-resumed call** (slicing a host-initiated call across
  frames): Q8 decides whether M9.1 ships run-to-completion only; slicing is additive.
- **Classes, `new`, promises, modules:** unchanged from ROADMAP ("deliberately not yet").
- **The C ABI (M9.2):** handle indices and the guard's depth model are chosen to make it
  thin, but it is designed separately.
- **`valueOf`/`toString` calling user functions** (revising D40): *proposed out* unless the
  review pulls it in (Q9) — the re-entrancy machinery makes it cheap, but it changes language
  behaviour the differential tests pin today.
- **Multiple threads per runtime:** still not planned (ROADMAP).

## Review questions

| # | question | options on the table |
|---|---|---|
| 1 | Native arguments: copied buffer, or minted handles? | buffer (one alloc per call, freed at return) vs handles (they double as the R1 fix and the GC story; unwinding must release them) |
| 2 | Handle representation | table+epoch (recommended) vs heap pin objects vs pin/unpin of raw Values |
| 3 | Handle release model | per-slot reference count (recommended) vs single-owner handles |
| 4 | Handle lifetime & ownership (review) | copies via `dup` only; refcounted slots; `Runtime.destroy` invalidates everything (E1 rule extended) — confirm, or demand scopes now |
| 5 | Native errors (review) | `rt.throwJs` for JS exceptions; existing error set for the rest; host aborts as `RangeError` throws (recommended) vs a new `error.HostError` kind |
| 6 | Host globals' home | realm `defineGlobalFunction` (recommended) vs compile-time `Options.globals` vs both |
| 7 | What a native may call back into | `rt.call`/constructors/readers/`throwJs`/`collectGarbage` allowed; `start`/`run`/`compile` forbidden — as `error.Busy` or panic (E2-style)? |
| 8 | `rt.call` slicing | run-to-completion under `limits.max_steps` in M9.1 (recommended; slicing additive) vs a `steps` parameter now |
| 9 | Revise D40 (user `valueOf`/`toString` become callable)? | in (cheap once re-entrancy exists; differential tests must move) vs out (keep `Unsupported(user_conversion)`) — recommended: out for M9.1 |
| 10 | String handles | handles for strings (needed to pass one back into JS) vs copy-out only — recommendation: handles, uniform model |
| 11 | Re-entrancy mechanism | A: nested frames + copied args (recommended) vs B: separate execution per callback (also the fallback) vs C: never-moving stacks (deferred) |
| 12 | Host-driven re-entry from inside a native | the host's *own* code calling the public API from a native (not via `rt.call`): panic (recommended — it is the M9.0 writer-overlap bug by another door) vs allow |

## Phases (draft; reshaped after the review)

- **P1 — design settle.** The questions above answered; the API sketch frozen as revision 2;
  D50+ written (handles, natives, re-entrancy, guard revision).
- **P2 — handles.** The table, mint/copy/read/release, root set, tests.
- **P3 — `rt.call` and the shared "run a closure" core.** Model B machinery first: it is
  needed by `rt.call` regardless of Q11, and it is the fallback.
- **P4 — host natives from JS.** `defineGlobalFunction`, the native frame (model A) or the
  cross-VM depth accounting (model B), errors and precision tests, R1's core test.
- **P5 — proof.** The acceptance list, `examples/` extended (a native + a callback),
  EMBEDDING.md, ROADMAP, the snapshot test's new approved names.
