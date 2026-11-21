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
    symbol: *const heap.Symbol,
    /// A function implemented in Zig. Becomes a function object in M7.
    native: *const Native,
    /// A function defined in the script (M6, M31 D62).
    closure: *const heap.Closure,
    /// An ordinary object or an array (M7).
    object: *heap.Object,

    pub fn isFunction(v: Value) bool {
        return v == .native or v == .closure or (v == .object and v.object.kind == .proxy and v.object.kind.proxy.is_callable);
    }

    pub fn isObjectLike(v: Value) bool {
        return v == .object or v == .closure or v == .native;
    }
};

/// A host native's internal callback (M9.1, D53): implemented in `src/api.zig`, which
/// mints the temporary argument tokens, pushes the native-call record, calls the host's
/// `NativeFn`, and copies the result out before releasing the tokens (D50).
pub const HostCallFn = fn (rt: *Runtime, ctx: ?*anyopaque, this: ?Value, args: []const Value) Error!Value;

pub const Native = struct {
    name: []const u8,
    length: u16 = 0,
    /// `this` is the call's receiver (`.undefined` for a plain call); `args` is a temporary
    /// slice owned by the caller, valid only during the call. A built-in native never calls
    /// back into JS (M7: conversions that would need to are Unsupported, D40).
    call: *const fn (rt: *Runtime, this: Value, args: []const Value) Error!Value,
    /// Set for host-registered globals (`defineGlobalFunction`, M9.1 D53): called instead
    /// of `call`, with `ctx` borrowed from the host until `Runtime.destroy`.
    host: ?struct {
        call: *const HostCallFn,
        ctx: ?*anyopaque,
    } = null,
    /// For built-in constructors (`Map`, `Set`): called by `new` instead of `call`.
    construct: ?*const fn (rt: *Runtime, args: []const Value) Error!Value = null,
    /// For the namespace globals (`Object`, `Array`, ..., `Error`, ...): where their static members live.
    namespace: ?enum {
        object,
        array,
        string,
        number,
        function,
        map,
        set,
        weak_map,
        weak_set,
        proxy,
        promise,
        @"error",
        type_error,
        range_error,
        syntax_error,
        reference_error,
        eval_error,
        uri_error,
        aggregate_error,
        regexp,
        symbol,
        array_buffer,
        data_view,
        typed_array,
        int8_array,
        uint8_array,
        uint8_clamped_array,
        int16_array,
        uint16_array,
        int32_array,
        uint32_array,
        float32_array,
        float64_array,
    } = null,
};
