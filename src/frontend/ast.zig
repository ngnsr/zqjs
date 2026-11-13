//! Abstract syntax tree. All nodes live in the arena passed to the parser
//! (DESIGN_DECISIONS D2) and point to each other directly (D3).

const std = @import("std");

pub const Span = struct { start: u32, end: u32 };

pub const UnaryOp = enum {
    neg,
    plus,
    not,

    pub fn symbol(op: UnaryOp) []const u8 {
        return switch (op) {
            .neg => "-",
            .plus => "+",
            .not => "!",
        };
    }
};

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    lt,
    le,
    gt,
    ge,
    strict_eq,
    strict_ne,
    /// `&&` and `||` short-circuit; the compiler treats them as control flow.
    logical_and,
    logical_or,

    pub fn symbol(op: BinaryOp) []const u8 {
        return switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
            .pow => "**",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
            .strict_eq => "===",
            .strict_ne => "!==",
            .logical_and => "&&",
            .logical_or => "||",
        };
    }
};

pub const Expr = struct {
    span: Span,
    /// 1 + depth of the deepest child; bounded by Limits.max_nesting_depth, so every
    /// recursive walk over the tree has bounded native stack use.
    depth: u16,
    data: Data,

    pub const Data = union(enum) {
        number: f64,
        /// UTF-16 code units, possibly containing lone surrogates (DESIGN_DECISIONS D6).
        string: []const u16,
        boolean: bool,
        null,
        unary: struct { op: UnaryOp, operand: *const Expr },
        binary: struct { op: BinaryOp, lhs: *const Expr, rhs: *const Expr },
    };
};

pub const Stmt = union(enum) {
    expression: *const Expr,
};

pub const Script = struct {
    statements: []const Stmt,
};

/// One S-expression per statement, e.g. `(+ 1 (* 2 3))`. A debugging format, not JS:
/// strings print non-printable or non-ASCII code units as `\uXXXX`.
pub fn dump(script: Script, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (script.statements) |s| switch (s) {
        .expression => |e| {
            try dumpExpr(e, w);
            try w.writeByte('\n');
        },
    };
}

pub fn dumpExpr(e: *const Expr, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (e.data) {
        .number => |n| try w.print("{d}", .{n}),
        .string => |units| {
            try w.writeByte('"');
            for (units) |u| switch (u) {
                '"', '\\' => try w.print("\\{c}", .{@as(u8, @intCast(u))}),
                0x20...0x21, 0x23...0x5B, 0x5D...0x7E => try w.writeByte(@intCast(u)),
                else => try w.print("\\u{X:0>4}", .{u}),
            };
            try w.writeByte('"');
        },
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .null => try w.writeAll("null"),
        .unary => |u| {
            try w.print("({s} ", .{u.op.symbol()});
            try dumpExpr(u.operand, w);
            try w.writeByte(')');
        },
        .binary => |b| {
            try w.print("({s} ", .{b.op.symbol()});
            try dumpExpr(b.lhs, w);
            try w.writeByte(' ');
            try dumpExpr(b.rhs, w);
            try w.writeByte(')');
        },
    }
}
