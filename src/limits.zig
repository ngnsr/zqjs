//! Resource limits (DESIGN_DECISIONS D15). A field is added in the milestone that first
//! enforces it, so every field here is actually checked somewhere.

const std = @import("std");

pub const Limits = struct {
    /// Largest accepted source text. Must stay below 4 GiB: token offsets are u32.
    max_source_bytes: u32 = 16 * 1024 * 1024,
    /// Bounds both parser recursion (e.g. nested parentheses) and AST depth (e.g. a long
    /// `1+1+…` chain, which the parser builds in a loop but later passes walk recursively).
    max_nesting_depth: u16 = 512,
    /// Execution budget. One step is charged for every statement executed, every
    /// expression evaluated and every loop iteration, so straight-line code, deep
    /// expressions and loops all consume it. Default: unlimited.
    max_steps: u64 = std.math.maxInt(u64),
    /// Runtime heap budget, in accounted bytes (see Heap.accountedSize).
    max_heap_bytes: usize = 256 * 1024 * 1024,
    /// Longest string, in UTF-16 code units.
    max_string_length: usize = 1 << 28,
};

pub const Limit = enum {
    source_bytes,
    nesting_depth,
    steps,
    heap_bytes,
    string_length,
};

comptime {
    std.debug.assert((Limits{}).max_source_bytes < std.math.maxInt(u32));
}
