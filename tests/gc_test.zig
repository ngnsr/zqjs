//! Garbage collector tests (M8). P0: the store-API invariant (GC_DESIGN I3): after
//! construction, every reference written into a heap object goes through the heap's
//! store functions, so a write barrier has one place to hook into.
//!
//! Zig has no field privacy, so this is enforced by scanning the files that touch heap
//! objects for the raw forms of a store. Reads stay direct. Exempt by design:
//!   - runtime/heap.zig itself (the store API and the constructors live there)
//!   - the VM's own locals and stacks (`vm.slot(...).* =`, `stack[...] =`): they are roots,
//!     not heap objects, and roots are never barriered (GC_DESIGN §7)
//!   - construction: filling an object nobody else can see yet (`newEnv` + `@memcpy` in the
//!     tree-walker's per-iteration copy); no pattern below matches it

const std = @import("std");
const testing = std.testing;

/// The files whose code holds heap objects (DESIGN_DECISIONS D7: only heap.zig allocates).
const scanned = [_][]const u8{
    "src/runtime/object.zig",
    "src/runtime/builtins.zig",
    "src/runtime/ops.zig",
    "src/vm/vm.zig",
    "src/interp/treewalk.zig",
    "src/bytecode/compiler.zig",
};

/// Why `line` is a raw store into a heap object, or null.
fn rawStore(line_in: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, line_in, " \t");
    if (std.mem.startsWith(u8, line, "//")) return null;
    const calls = [_]struct { []const u8, []const u8 }{
        .{ ".props.put(", "property store: use heap.storeProperty/defineProperty" },
        .{ ".props.getOrPut(", "property store: use heap.storeProperty/defineProperty" },
        .{ ".props.orderedRemove(", "property delete: use heap.removeProperty" },
        .{ ".props.swapRemove(", "property delete: use heap.removeProperty" },
        .{ ".kind.array.append", "element store: use heap.appendElement(s)" },
        .{ "elements.append", "element store: use heap.appendElement(s)" },
        .{ ".kind.array.pop(", "element removal: use heap.popElement" },
        .{ "elements.pop(", "element removal: use heap.popElement" },
        .{ "elements.shrink", "element removal: use heap.shrinkElements" },
    };
    for (calls) |c| if (std.mem.indexOf(u8, line, c[0]) != null) return c[1];
    // Indexed writes into an element list, an environment record or a capture list.
    if (std.mem.indexOf(u8, line, "] = ") != null) {
        if (std.mem.indexOf(u8, line, "items[") != null and std.mem.indexOf(u8, line, "stack[") == null)
            return "element store: use heap.storeElement";
        if (std.mem.indexOf(u8, line, ".values[") != null) return "environment store: use heap.storeEnv";
        if (std.mem.indexOf(u8, line, "captures[") != null) return "capture store: only heap.zig constructors";
    }
    // `cell.value = …` and `obj.proto = …`: a field write on an expression, not a struct
    // literal field (`.{ .value = … }`, where `.value` follows a space or brace).
    for ([_]struct { []const u8, []const u8 }{
        .{ ".value = ", "cell store: use heap.storeCell" },
        .{ ".proto = ", "prototype store: only heap.zig constructors" },
    }) |f| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, line, at, f[0])) |i| : (at = i + 1) {
            if (i > 0 and (std.ascii.isAlphanumeric(line[i - 1]) or line[i - 1] == '_' or line[i - 1] == ')')) return f[1];
        }
    }
    return null;
}

test "the scanner flags every raw-store form it claims to" {
    for ([_][]const u8{
        "o.props.put(a, k, v);",
        "_ = o.props.getOrPut(a, k);",
        "_ = o.props.orderedRemove(k);",
        "arr.kind.array.append(a, v) catch {};",
        "try elements.appendSlice(a, vs);",
        "_ = elements.pop();",
        "elements.shrinkRetainingCapacity(n);",
        "elements.items[i] = v;",
        "rec.values[i] = v;",
        "c.impl.vm.captures[0] = cell;",
        "c.value = v;",
        "vm.cellAt(i).value = v;",
        "o.proto = p;",
    }) |line| if (rawStore(line) == null) {
        std.debug.print("not flagged: {s}\n", .{line});
        return error.TestUnexpectedResult;
    };
    // And leaves reads, struct literals, roots and comments alone.
    for ([_][]const u8{
        "const v = elements.items[i];",
        "s.* = .{ .value = vm.peek(0) };",
        "vm.stack[base] = result;",
        "return it.envOf(b).values[i];",
        "// c.value = v; in a comment",
        "o.* = .{ .obj = x, .proto = proto };",
    }) |line| if (rawStore(line)) |why| {
        std.debug.print("wrongly flagged ({s}): {s}\n", .{ why, line });
        return error.TestUnexpectedResult;
    };
}

test "every store into a heap object goes through the heap's store API (I3)" {
    const io = testing.io;
    const gpa = testing.allocator;
    var violations: usize = 0;
    for (scanned) |path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 22));
        defer gpa.free(text);
        // The unit tests at the end of a file build objects by hand; only code is scanned.
        const code = if (std.mem.indexOf(u8, text, "\ntest \"")) |t| text[0..t] else text;
        var lines = std.mem.splitScalar(u8, code, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            n += 1;
            if (rawStore(line)) |why| {
                std.debug.print("{s}:{d}: {s}\n    {s}\n", .{ path, n, why, std.mem.trim(u8, line, " \t") });
                violations += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), violations);
}
