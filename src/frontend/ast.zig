//! Abstract syntax tree. All nodes live in the arena passed to the parser
//! (DESIGN_DECISIONS D2) and point to each other directly (D3). The tree is never
//! modified after parsing: name resolution goes into side tables (D20).
//!
//! Names (`Ref.name`, `Declarator.name`) are slices of the source text, so the
//! source must outlive the AST.

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

/// A use of a variable name. `id` indexes `Resolution.refs` (resolver.zig).
pub const Ref = struct {
    name: []const u8,
    span: Span,
    id: u32,
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
        identifier: Ref,
        unary: struct { op: UnaryOp, operand: *const Expr },
        binary: struct { op: BinaryOp, lhs: *const Expr, rhs: *const Expr },
        /// `target = value` (op null) or `target op= value`.
        assign: struct { op: ?BinaryOp, target: Ref, value: *const Expr },
        /// `callee(args)`. In M3 only native functions (`print`) can be called.
        call: struct { callee: *const Expr, args: []const *const Expr },
        /// `++x`, `--x`, `x++`, `x--`.
        update: struct { op: enum { inc, dec }, prefix: bool, target: Ref },
    };
};

pub const DeclKind = enum { let, @"const" };

pub const Declarator = struct {
    name: []const u8,
    span: Span,
    /// Index into `Resolution.bindings`.
    binding: u32,
    init: ?*const Expr,
};

pub const Declaration = struct {
    kind: DeclKind,
    declarators: []const Declarator,
};

pub const Stmt = struct {
    span: Span,
    data: Data,

    pub const Data = union(enum) {
        empty,
        expression: *const Expr,
        declaration: Declaration,
        block: []const Stmt,
        @"if": struct { cond: *const Expr, then: *const Stmt, @"else": ?*const Stmt },
        @"while": struct { cond: *const Expr, body: *const Stmt },
        /// The head declaration (if any) lives in its own scope around the body. Its
        /// bindings are the ones the spec copies per iteration (DESIGN_DECISIONS D22).
        @"for": struct { init: ?ForInit, cond: ?*const Expr, update: ?*const Expr, body: *const Stmt },
        @"break",
        @"continue",
    };
};

pub const ForInit = union(enum) {
    declaration: Declaration,
    expression: *const Expr,
};

pub const Script = struct {
    statements: []const Stmt,
    /// Number of `Ref`s and `Declarator`s, so the resolver can size its tables exactly.
    ref_count: u32,
    binding_count: u32,
};
