//! The global names a script can read: `undefined`, `NaN`, `Infinity`, `print`.
//! Looked up by name each time (shortcut: a linear string compare per global read;
//! M7 gives globals a real object with atom keys).

const std = @import("std");
const Value = @import("value.zig").Value;
const Native = @import("value.zig").Native;
const rt_mod = @import("runtime.zig");
const Runtime = rt_mod.Runtime;
const Error = rt_mod.Error;
const ops = @import("ops.zig");

pub fn lookup(name: []const u8) ?Value {
    if (std.mem.eql(u8, name, "undefined")) return .undefined;
    if (std.mem.eql(u8, name, "NaN")) return .{ .number = std.math.nan(f64) };
    if (std.mem.eql(u8, name, "Infinity")) return .{ .number = std.math.inf(f64) };
    if (std.mem.eql(u8, name, "print")) return .{ .native = &print };
    return null;
}

/// `print(a, b, …)` writes `String(a) + " " + String(b) + … + "\n"`. The node test
/// harness defines the same function, so outputs compare byte for byte.
pub const print: Native = .{ .name = "print", .call = printImpl };

fn printImpl(rt: *Runtime, args: []const Value) Error!Value {
    for (args, 0..) |arg, i| {
        if (i > 0) try rt.out.writeByte(' ');
        var buf: ops.NumberBuf = undefined;
        switch (try ops.toPiece(rt, arg, &buf)) {
            .ascii => |s| try rt.out.writeAll(s),
            .utf16 => |units| try ops.writeUtf16(rt.out, units),
        }
    }
    try rt.out.writeByte('\n');
    return .undefined;
}
