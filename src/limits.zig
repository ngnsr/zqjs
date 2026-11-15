//! Resource limits (DESIGN_DECISIONS D15). A field is added in the milestone that first
//! enforces it, so every field here is actually checked somewhere.

const std = @import("std");

pub const Limits = struct {
    /// Largest accepted source text. Must stay below 4 GiB: token offsets are u32.
    max_source_bytes: u32 = 16 * 1024 * 1024,
    /// Bounds both parser recursion (e.g. nested parentheses) and AST depth (e.g. a long
    /// `1+1+…` chain, which the parser builds in a loop but later passes walk recursively).
    max_nesting_depth: u16 = 512,
    /// Execution budget, charged before the work it pays for. The unit is engine-defined:
    /// the VM charges one step per executed instruction; the tree-walker one per statement
    /// executed, expression evaluated and loop iteration. So straight-line code, deep
    /// expressions and loops all consume it, but the same script uses different amounts
    /// in each engine: thresholds are not a cross-engine guarantee. Default: unlimited.
    max_steps: u64 = std.math.maxInt(u64),
    /// Runtime heap budget, in accounted bytes (see Heap.accountedSize).
    max_heap_bytes: usize = 256 * 1024 * 1024,
    /// Young generation size (M8.1): a minor collection is requested once this many
    /// accounted bytes have been allocated since the last collection (or half the room
    /// left under `max_heap_bytes`, if that is less). Measured (M8.1 P2, 256K-4M): a
    /// minor pause is proportional to it, total GC time isn't (it follows the garbage),
    /// and a nursery that outgrows the cache sweeps slower; so the smallest that doesn't
    /// promote much short-lived data.
    nursery_bytes: usize = 256 * 1024,
    /// Longest string, in UTF-16 code units.
    max_string_length: usize = 1 << 28,
    /// Largest bytecode of one compiled script, in bytes. Must stay below 4 GiB: jump
    /// targets are u32 byte offsets. Code is several times larger than its source
    /// (`a;` is 2 bytes of source, 10 of code), hence 4× the source limit.
    max_code_bytes: u32 = 64 * 1024 * 1024,
    /// Most entries in one compiled script's constant pool, and separately in its name
    /// table. Operands are u32, so this is a resource bound, not an encoding one.
    max_constants: u32 = 1 << 20,
    /// Most active JavaScript calls (frames) at once, on both engines. Node allows about
    /// 11k before its RangeError; we stop a little earlier with LimitExceeded(call_depth).
    max_call_depth: u32 = 10_000,
    /// VM: the most stack slots reserved at once, summed over *all active frames*: each
    /// frame reserves its `slot_count` locals plus its `max_stack` operands on entry,
    /// whether or not it uses them, so a deep recursion of small frames and a shallow one
    /// of huge frames are both bounded. LimitExceeded(stack_slots) (DESIGN_DECISIONS D36).
    max_stack_slots: u32 = 1 << 22,
    /// Tree-walker: the deepest native recursion of the interpreter, counting every
    /// statement, expression and call it is nested in, across function calls. Bounds
    /// its use of the Zig stack, so deep recursion stops cleanly with
    /// LimitExceeded(interpreter_depth) instead of overflowing the OS stack. Sized
    /// (DESIGN_DECISIONS D37) to stay well inside an 8 MiB stack in Debug builds.
    max_interpreter_depth: u32 = 6_000,
    /// Nesting of built-in conversions that recurse in Zig: converting an array to a
    /// string converts its elements (`[[[…]]]`). LimitExceeded(conversion_depth).
    max_conversion_depth: u32 = 1_000,
    /// Host handles (M9.1, D50): the most token records ever minted on this runtime —
    /// host-owned and engine-owned temporary tokens (native-call records, D53) alike —
    /// cumulative over the runtime's lifetime, **not** the currently-live count. Token
    /// records are never reused (a released one must stay detectable), so a host that
    /// mints and releases in a loop consumes records until this cap even with nothing
    /// held: LimitExceeded(handles), catchable, runtime stays usable (E6). Re-entrancy
    /// depth multiplies the burn (each native crossing mints its arguments' tokens from
    /// the same pool), so size the cap with the workload's nesting in mind. Slots are
    /// recycled, so the cap bounds the pool's memory, not the values' lifetimes.
    max_handles: u32 = 1 << 18,
};

/// Elements per card (M8.1): an array with at least this capacity records young stores
/// per card, so a minor collection rescans only the dirty cards, not the whole array.
pub const card_elements = 512;

pub const Limit = enum {
    source_bytes,
    nesting_depth,
    steps,
    heap_bytes,
    string_length,
    code_bytes,
    constants,
    call_depth,
    stack_slots,
    interpreter_depth,
    conversion_depth,
    handles,
};

comptime {
    std.debug.assert((Limits{}).max_source_bytes < std.math.maxInt(u32));
    std.debug.assert((Limits{}).max_code_bytes < std.math.maxInt(u32));
}
