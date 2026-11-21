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
    /// Native stack the engines may use below the host's entry point, checked at every
    /// native→JS crossing (a built-in or host native calling JS), each of which nests a
    /// Zig run loop: 3.6–72 KB per crossing by engine and build mode. The host's thread
    /// needs this plus ≥ 128 KiB of headroom; lower it on small threads.
    /// LimitExceeded(native_stack) (DESIGN_DECISIONS D60).
    max_native_stack_bytes: usize = 4 * 1024 * 1024,
    /// Host handles (M9.1, D50): maximum slot / concurrent handle capacity on this
    /// runtime — host-owned handles and engine-owned callback temporaries (native-call
    /// records, D53) alike. Released slots increment their 64-bit generation and return
    /// to the free list for reuse (retired only on `u64` wraparound), so long-running
    /// hosts can mint and release handles in a loop indefinitely without growing the
    /// table or hitting this cap. Exceeding it returns `LimitExceeded(handles)`,
    /// catchable, leaving the runtime usable (E6).
    max_handles: u32 = 1 << 18,
    /// Maximum number of ES modules loaded in one Runtime (M42, D72).
    max_modules: u32 = 1024,
    /// Maximum size of a BigInt in bits (M47, D77). Exceeding throws RangeError.
    max_bigint_bits: u32 = 1 << 20,
};

/// Elements per card (M8.1): an array with at least this capacity records young stores
/// per card, so a minor collection rescans only the dirty cards, not the whole array.
pub const card_elements = 512;

/// Compile-time and structural ceilings for a single RegExp pattern (D61).
/// Group/lookahead nesting is checked against `Limits.max_nesting_depth` (default 512);
/// exceeding the structural ceilings below reports `LimitExceeded(code_bytes)`.
pub const regex_max_depth: u16 = 512;
pub const regex_max_program_insts: u32 = 65_536;
pub const regex_max_class_items: u32 = 65_536;
pub const regex_max_loops: u16 = 4_096;
pub const regex_max_captures: u16 = 4_096;
pub const regex_max_quantifier_bound: u32 = 65_535;
pub const regex_max_backtrack_states: u32 = std.math.maxInt(u32) - 1;
pub const regex_max_backtrack_cells: u32 = std.math.maxInt(u32) - @as(u32, regex_max_captures) * 2;

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
    native_stack,
    modules,
};

comptime {
    std.debug.assert((Limits{}).max_source_bytes < std.math.maxInt(u32));
    std.debug.assert((Limits{}).max_code_bytes < std.math.maxInt(u32));
}
