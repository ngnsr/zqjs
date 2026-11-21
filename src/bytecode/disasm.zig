//! Human-readable listing of a Proto (`zqjs --dump-bytecode`, and each line of
//! `--trace`). Only for verified bytecode: it trusts operands to be in range.
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
//! Operands: sN slot, kN constant, nN name, @N jump target (byte offset), plain N argc,
//! #N nested function, ^N capture. Nested functions follow, as `function #1.2 name`.
//! The comment shows the constant's value or the name.

const std = @import("std");
const Writer = std.Io.Writer;
const ops = @import("../runtime/ops.zig");
const Value = @import("../runtime/value.zig").Value;
const bc = @import("bytecode.zig");
const Op = bc.Op;
const Proto = bc.Proto;

pub fn disassemble(p: Proto, w: *Writer) Writer.Error!void {
    var path: [64]u32 = undefined; // nesting is bounded by the AST depth limit; deeper is elided
    try listing(p, &path, 0, w);
}

/// One Proto, then its functions depth-first, numbered by path (#1, #1.2, …).
fn listing(p: Proto, path: []u32, depth: usize, w: *Writer) Writer.Error!void {
    if (depth > 0) {
        try w.writeAll("\nfunction #");
        for (path[0..depth], 0..) |n, i| try w.print("{s}{d}", .{ if (i > 0) "." else "", n });
        try w.print(" {s}: params {d}", .{ if (p.name.len > 0) p.name else "(anonymous)", p.param_count });
        if (p.param_count > 0 and p.param_slot > 0) try w.print(" from s{d}", .{p.param_slot});
        if (p.captures.len > 0) try w.writeAll(", captures");
        for (p.captures) |c| try w.print(" {s}{d}", .{ if (c.from == .parent_slot) "s" else "^", c.index });
        try w.writeByte('\n');
    }
    try w.print("slots {d}, max_stack {d}, code {d} bytes\n", .{ p.slot_count, p.max_stack, p.code.len });
    if (p.consts.len > 0) try w.writeAll("constants\n");
    for (p.consts, 0..) |k, i| {
        try w.print("  k{d}  ", .{i});
        try value(k, w);
        try w.writeByte('\n');
    }
    if (p.names.len > 0) try w.writeAll("names\n");
    for (p.names, 0..) |n, i| try w.print("  n{d}  {s}\n", .{ i, n });

    try w.writeAll("code\n");
    var pc: usize = 0;
    while (pc < p.code.len) : (pc += @as(Op, @fromBackingInt(@intCast(p.code[pc]))).size()) {
        try instruction(p, pc, w);
        try w.writeByte('\n');
    }
    for (p.functions, 1..) |f, i| {
        if (depth >= path.len) return w.writeAll("\n(deeper functions elided)\n");
        path[depth] = @intCast(i);
        try listing(f, path, depth + 1, w);
    }
}

/// One line of the listing (no newline) for the instruction at `pc`. Also used by
/// `--trace`, so traces and listings look the same.
pub fn instruction(p: Proto, pc: usize, w: *Writer) Writer.Error!void {
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
            .function => line.print("#{d}", .{x + 1}) catch unreachable, // the listing numbers from 1
            .capture => line.print("^{d}", .{x}) catch unreachable,
            .repl => line.print("r{d}", .{x}) catch unreachable,
        }
    }
    if (comment == null and comment_name == null) return w.writeAll(std.mem.trimEnd(u8, line.buffered(), " "));
    try w.print("{s:<37} ; ", .{line.buffered()});
    if (comment) |k| try value(k, w) else try w.writeAll(comment_name.?);
}

/// A value as the listing and the trace show it. Numbers as JS prints them (but -0 as
/// "-0"); strings quoted, with everything outside printable ASCII (including lone
/// surrogates) as \uXXXX, so output is plain ASCII.
pub fn value(v: Value, w: *Writer) Writer.Error!void {
    switch (v.unpack()) {
        .undefined, .null => try w.writeAll(@tagName(v.tag())),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .native => |n| try w.print("<native {s}>", .{n.name}),
        .closure => try w.writeAll("<function>"),
        .symbol => |s| {
            try w.writeAll("Symbol(");
            if (s.description) |d| {
                for (d.units) |u| switch (u) {
                    0x20...0x7e => try w.writeByte(@intCast(u)),
                    else => try w.print("\\u{X:0>4}", .{u}),
                };
            }
            try w.writeByte(')');
        },
        .object => |o| try w.writeAll(switch (o.kind) {
            .array => "<array>",
            .regexp => "<regexp>",
            else => "<object>",
        }),
        .number => |n| {
            var buf: ops.NumberBuf = undefined;
            if (n == 0 and std.math.signbit(n)) try w.writeAll("-0") else try w.writeAll(ops.formatNumber(&buf, n));
        },
        .bigint => |b| {
            if (b.limbs.len == 0) {
                try w.writeAll("0n");
            } else {
                try w.print("<bigint:{d}-limbs>", .{b.limbs.len});
            }
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
    }
}
