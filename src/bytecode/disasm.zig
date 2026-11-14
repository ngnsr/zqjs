//! Human-readable listing of a Proto (`zqjs --dump-bytecode`). Only for verified
//! bytecode: it trusts operands to be in range.
//!
//!   slots 1, max_stack 2, code 35 bytes
//!   constants
//!     k0  1
//!   names
//!     n0  x
//!   code
//!        0  clear_local    s0
//!        5  push_const     k0            ; 1
//!       10  init_local     s0
//!       15  get_local      s0 n0         ; x
//!   …
//! Operands: sN slot, kN constant, nN name, @N jump target (byte offset), plain N argc.
//! The comment shows the constant's value or the name.

const std = @import("std");
const Writer = std.Io.Writer;
const ops = @import("../runtime/ops.zig");
const Value = @import("../runtime/value.zig").Value;
const bc = @import("bytecode.zig");
const Op = bc.Op;
const Proto = bc.Proto;

pub fn disassemble(p: Proto, w: *Writer) Writer.Error!void {
    try w.print("slots {d}, max_stack {d}, code {d} bytes\n", .{ p.slot_count, p.max_stack, p.code.len });
    if (p.consts.len > 0) try w.writeAll("constants\n");
    for (p.consts, 0..) |k, i| {
        try w.print("  k{d}  ", .{i});
        try constant(k, w);
        try w.writeByte('\n');
    }
    if (p.names.len > 0) try w.writeAll("names\n");
    for (p.names, 0..) |n, i| try w.print("  n{d}  {s}\n", .{ i, n });

    try w.writeAll("code\n");
    var pc: usize = 0;
    while (pc < p.code.len) : (pc += @as(Op, @fromBackingInt(@intCast(p.code[pc]))).size()) {
        const op: Op = @fromBackingInt(@intCast(p.code[pc]));
        var buf: [96]u8 = undefined; // offset, opcode and at most two u32 operands
        var line: Writer = .fixed(&buf);
        line.print("  {d:>5}  {s:<14} ", .{ pc, @tagName(op) }) catch unreachable;
        var comment: ?Value = null;
        var comment_name: ?[]const u8 = null;
        for (op.info().operands, 0..) |kind, i| {
            const x = bc.readU32(p.code, pc + 1 + 4 * i);
            if (i > 0) line.writeByte(' ') catch unreachable;
            switch (kind) {
                .slot => line.print("s{d}", .{x}) catch unreachable,
                .@"const" => {
                    line.print("k{d}", .{x}) catch unreachable;
                    comment = p.consts[x];
                },
                .name => {
                    line.print("n{d}", .{x}) catch unreachable;
                    comment_name = p.names[x];
                },
                .target => line.print("@{d}", .{x}) catch unreachable,
                .argc => line.print("{d}", .{x}) catch unreachable,
            }
        }
        if (comment == null and comment_name == null) {
            try w.print("{s}\n", .{std.mem.trimEnd(u8, line.buffered(), " ")});
            continue;
        }
        try w.print("{s:<37} ; ", .{line.buffered()});
        if (comment) |k| try constant(k, w) else try w.writeAll(comment_name.?);
        try w.writeByte('\n');
    }
}

/// Numbers as JS prints them; strings quoted, with everything outside printable
/// ASCII (including lone surrogates) as \uXXXX, so the listing is plain ASCII.
fn constant(k: Value, w: *Writer) Writer.Error!void {
    switch (k) {
        .number => |n| {
            var buf: ops.NumberBuf = undefined;
            // -0 prints as "0" in JS; the listing must tell them apart.
            if (n == 0 and std.math.signbit(n)) try w.writeAll("-0") else try w.writeAll(ops.formatNumber(&buf, n));
        },
        .string => |s| {
            try w.writeByte('"');
            for (s.units) |u| switch (u) {
                '"', '\\' => try w.print("\\{c}", .{@as(u8, @intCast(u))}),
                0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try w.writeByte(@intCast(u)),
                else => try w.print("\\u{X:0>4}", .{u}),
            };
            try w.writeByte('"');
        },
        else => unreachable, // the verifier allows numbers and strings only
    }
}
