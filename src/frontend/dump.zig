//! Debug output: one S-expression per top-level statement, with resolved names.
//!   x#3@1     declaration of x as binding 3 in slot 1
//!   x#3@c1    same, but captured by an inner function (slot 1 holds its cell)
//!   x#3       reference to binding 3
//!   x#3^0     reference to binding 3 of an outer function, through capture 0
//!   x@global  reference to an undeclared (global) name
//!   (function f#1@0 (params…) (captures x#3…) body…)
//! Strings print non-printable or non-ASCII code units as `\uXXXX`. Not JS syntax.

const std = @import("std");
const ast = @import("ast.zig");
const Resolution = @import("resolver.zig").Resolution;

const W = *std.Io.Writer;
const Error = std.Io.Writer.Error;

pub fn script(s: ast.Script, res: Resolution, w: W) Error!void {
    const d: Dumper = .{ .res = res, .w = w };
    for (s.statements) |st| {
        try d.stmt(st);
        try w.writeByte('\n');
    }
}

const Dumper = struct {
    res: Resolution,
    w: W,

    fn stmt(d: Dumper, s: ast.Stmt) Error!void {
        const w = d.w;
        switch (s.data) {
            .empty => try w.writeAll("(empty)"),
            .@"break" => try w.writeAll("(break)"),
            .@"continue" => try w.writeAll("(continue)"),
            .function => |f| try d.function(f),
            .@"return" => |v| {
                try w.writeAll("(return");
                if (v) |e| {
                    try w.writeByte(' ');
                    try d.expr(e);
                }
                try w.writeByte(')');
            },
            .expression => |e| try d.expr(e),
            .declaration => |decl| try d.declaration(decl),
            .block => |stmts| {
                try w.writeAll("(block");
                for (stmts) |child| {
                    try w.writeByte(' ');
                    try d.stmt(child);
                }
                try w.writeByte(')');
            },
            .@"if" => |i| {
                try w.writeAll("(if ");
                try d.expr(i.cond);
                try w.writeByte(' ');
                try d.stmt(i.then.*);
                if (i.@"else") |e| {
                    try w.writeByte(' ');
                    try d.stmt(e.*);
                }
                try w.writeByte(')');
            },
            .@"while" => |wh| {
                try w.writeAll("(while ");
                try d.expr(wh.cond);
                try w.writeByte(' ');
                try d.stmt(wh.body.*);
                try w.writeByte(')');
            },
            .@"for" => |f| {
                try w.writeAll("(for ");
                if (f.init) |init| switch (init) {
                    .declaration => |decl| try d.declaration(decl),
                    .expression => |e| try d.expr(e),
                } else try w.writeByte('_');
                try w.writeByte(' ');
                try d.optExpr(f.cond);
                try w.writeByte(' ');
                try d.optExpr(f.update);
                try w.writeByte(' ');
                try d.stmt(f.body.*);
                try w.writeByte(')');
            },
        }
    }

    fn binding(d: Dumper, dc: ast.Declarator) Error!void {
        const b = d.res.bindings[dc.binding];
        try d.w.print("{s}#{d}@{s}{d}", .{ dc.name, dc.binding, if (b.captured) "c" else "", b.slot });
    }

    fn function(d: Dumper, f: *const ast.Function) Error!void {
        const w = d.w;
        try w.writeAll("(function ");
        if (f.name) |n| try d.binding(n) else try w.writeByte('_');
        try w.writeAll(" (");
        for (f.params, 0..) |p, i| {
            if (i > 0) try w.writeByte(' ');
            try d.binding(p);
        }
        try w.writeByte(')');
        const captures = d.res.functions[f.id].captures;
        if (captures.len > 0) {
            try w.writeAll(" (captures");
            for (captures) |c| try w.print(" #{d}", .{c.binding});
            try w.writeByte(')');
        }
        for (f.body) |st| {
            try w.writeByte(' ');
            try d.stmt(st);
        }
        try w.writeByte(')');
    }

    fn declaration(d: Dumper, decl: ast.Declaration) Error!void {
        try d.w.print("({s}", .{@tagName(decl.kind)});
        for (decl.declarators) |dc| {
            try d.w.writeAll(" (");
            try d.binding(dc);
            if (dc.init) |init| {
                try d.w.writeByte(' ');
                try d.expr(init);
            }
            try d.w.writeByte(')');
        }
        try d.w.writeByte(')');
    }

    fn optExpr(d: Dumper, e: ?*const ast.Expr) Error!void {
        if (e) |x| try d.expr(x) else try d.w.writeByte('_');
    }

    fn ref(d: Dumper, r: ast.Ref) Error!void {
        switch (d.res.refs[r.id]) {
            .local => |b| try d.w.print("{s}#{d}", .{ r.name, b }),
            .capture => |c| try d.w.print("{s}#{d}^{d}", .{ r.name, c.binding, c.index }),
            .global => try d.w.print("{s}@global", .{r.name}),
        }
    }

    fn expr(d: Dumper, e: *const ast.Expr) Error!void {
        const w = d.w;
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
            .identifier => |r| try d.ref(r),
            .unary => |u| {
                try w.print("({s} ", .{u.op.symbol()});
                try d.expr(u.operand);
                try w.writeByte(')');
            },
            .binary => |b| {
                try w.print("({s} ", .{b.op.symbol()});
                try d.expr(b.lhs);
                try w.writeByte(' ');
                try d.expr(b.rhs);
                try w.writeByte(')');
            },
            .assign => |a| {
                if (a.op) |op| try w.print("({s}= ", .{op.symbol()}) else try w.writeAll("(= ");
                try d.ref(a.target);
                try w.writeByte(' ');
                try d.expr(a.value);
                try w.writeByte(')');
            },
            .call => |c| {
                try w.writeAll("(call ");
                try d.expr(c.callee);
                for (c.args) |arg| {
                    try w.writeByte(' ');
                    try d.expr(arg);
                }
                try w.writeByte(')');
            },
            .function => |f| try d.function(f),
            .update => |u| {
                const sym = if (u.op == .inc) "++" else "--";
                try w.print("({s}{s} ", .{ if (u.prefix) "pre" else "post", sym });
                try d.ref(u.target);
                try w.writeByte(')');
            },
        }
    }
};
