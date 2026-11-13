//! JavaScript values (DESIGN_DECISIONS D5). Only this file knows the layout.

const heap = @import("heap.zig");
const Runtime = @import("runtime.zig").Runtime;
const Error = @import("runtime.zig").Error;

pub const Value = union(enum) {
    undefined,
    null,
    boolean: bool,
    number: f64,
    string: *const heap.String,
    /// A function implemented in Zig. Becomes a function object in M7.
    native: *const Native,
};

pub const Native = struct {
    name: []const u8,
    /// `args` is a temporary slice owned by the caller, valid only during the call.
    call: *const fn (rt: *Runtime, args: []const Value) Error!Value,
};
