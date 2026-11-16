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
    /// `key in object` (M7).
    in,
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
            .in => "in",
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

/// A property key as written (M7). `name`: an identifier or keyword after `.` or in a
/// literal (ASCII); `string` / `number`: a literal key; `computed`: `[expr]`.
pub const PropertyKey = union(enum) {
    name: []const u8,
    string: []const u16,
    number: f64,
    computed: *const Expr,
};

/// `object.name` or `object[expr]` (only `name` and `computed` keys occur here).
pub const Member = struct {
    object: *const Expr,
    key: PropertyKey,
};

/// What an assignment or `++`/`--` writes to.
pub const Target = union(enum) {
    ref: Ref,
    member: Member,
};

pub const PropertyDef = struct {
    key: PropertyKey,
    value: *const Expr,
    span: Span,
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
        conditional: struct { cond: *const Expr, then_expr: *const Expr, else_expr: *const Expr },
        /// `target = value` (op null) or `target op= value`.
        assign: struct { op: ?BinaryOp, target: Target, value: *const Expr },
        /// `callee(args)`. A member callee (`o.f(…)`) is a method call: `this` is `o`.
        call: struct { callee: *const Expr, args: []const *const Expr },
        /// `++x`, `--x`, `x++`, `x--`.
        update: struct { op: enum { inc, dec }, prefix: bool, target: Target },
        member: Member,
        /// `{ key: value, … }`, in source order.
        object: []const PropertyDef,
        /// `[a, b, …]` (no holes: the parser rejects them).
        array: []const *const Expr,
        /// `delete object.name` / `delete object[expr]`.
        delete: Member,
        /// `this`, only inside functions (at script level: Unsupported).
        this,
        /// `function [name](params) { body }` as an expression.
        function: *const Function,
    };
};

/// A function declaration or expression (M6).
pub const Function = struct {
    span: Span,
    /// Index into `Resolution.functions`; 0 is the script itself, so functions count from 1.
    id: u32,
    kind: enum { declaration, expression },
    /// Required for declarations (bound in the enclosing scope); optional for
    /// expressions (bound only inside the function, DESIGN_DECISIONS D36).
    name: ?Declarator,
    /// Plain identifiers only (no defaults, rest or destructuring). `init` is always null.
    params: []const Declarator,
    body: []const Stmt,
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
        /// Only at the top level of a script or a function body (blocks: Unsupported).
        function: *const Function,
        /// `return [value];`, only inside a function.
        @"return": ?*const Expr,
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
    /// Number of functions plus one (the script is function 0).
    function_count: u32,
};
