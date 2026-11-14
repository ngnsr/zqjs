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
    /// A function defined in the script (M6). Not an object yet: property access on it
    /// is Unsupported(function_properties) (M7).
    closure: *const heap.Closure,
    /// An ordinary object or an array (M7).
    object: *heap.Object,

    pub fn isFunction(v: Value) bool {
        return v == .native or v == .closure;
    }
};

pub const Native = struct {
    name: []const u8,
    /// `this` is the call's receiver (`.undefined` for a plain call); `args` is a temporary
    /// slice owned by the caller, valid only during the call. A native never calls back
    /// into JS (M7: conversions that would need to are Unsupported, D40).
    call: *const fn (rt: *Runtime, this: Value, args: []const Value) Error!Value,
    /// For the namespace globals (`Object`, `Array`): where their static members live.
    namespace: ?enum { object, array } = null,
};
