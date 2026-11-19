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
    bit_not,
    typeof,

    pub fn symbol(op: UnaryOp) []const u8 {
        return switch (op) {
            .neg => "-",
            .plus => "+",
            .not => "!",
            .bit_not => "~",
            .typeof => "typeof",
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
    shl,
    shr,
    ushr,
    bit_and,
    bit_xor,
    bit_or,
    lt,
    le,
    gt,
    ge,
    strict_eq,
    strict_ne,
    /// `key in object` (M7).
    in,
    /// `lhs instanceof rhs` (M25).
    instanceof,
    /// `&&`, `||`, and `??` short-circuit; the compiler treats them as control flow.
    logical_and,
    logical_or,
    nullish,
    comma,

    pub fn symbol(op: BinaryOp) []const u8 {
        return switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
            .pow => "**",
            .shl => "<<",
            .shr => ">>",
            .ushr => ">>>",
            .bit_and => "&",
            .bit_xor => "^",
            .bit_or => "|",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
            .strict_eq => "===",
            .strict_ne => "!==",
            .in => "in",
            .instanceof => "instanceof",
            .logical_and => "&&",
            .logical_or => "||",
            .nullish => "??",
            .comma => ",",
        };
    }
};

pub const AssignOp = union(enum) {
    plain,
    compound: BinaryOp,
    logical_and,
    logical_or,
    nullish,
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

/// An optional chain starting at the first `?.` (M24).
pub const OptionalChain = struct {
    base: *const Expr,
    steps: []const Step,

    pub const Step = struct {
        optional: bool,
        kind: Kind,
    };

    pub const Kind = union(enum) {
        prop: []const u8,
        elem: *const Expr,
        call: []const *const Expr,
    };
};

/// What an assignment or `++`/`--` writes to.
pub const Target = union(enum) {
    ref: Ref,
    member: Member,
    super_member: PropertyKey,
};

pub const PropertyDef = union(enum) {
    prop: struct {
        key: PropertyKey,
        value: *const Expr,
        shorthand: bool,
        span: Span,
    },
    spread: struct {
        expr: *const Expr,
        span: Span,
    },
    /// CoverInitializedName `{ a = 1 }`: only valid when reinterpreted as a pattern.
    cover_init: struct {
        ref: Ref,
        default: *const Expr,
        span: Span,
    },
};

/// A destructuring or assignment pattern (M26).
/// `depth` counts nesting toward `Limits.max_nesting_depth`.
pub const Pattern = struct {
    span: Span,
    depth: u16,
    data: Data,

    pub const Data = union(enum) {
        /// Binding leaf (`let`/`const`/param/`catch`/`for-of` decl).
        binding: Declarator,
        /// Assignment target leaf (`[x, o.y] = ...`).
        target: Target,
        /// `[elem0, , elem2, ...rest]` (`null` element = hole).
        array: struct {
            elems: []const ?Elem,
            rest: ?*const Pattern,
        },
        /// `{ prop0, prop1, ...rest }`.
        object: struct {
            props: []const Prop,
            rest: ?*const Pattern,
        },
    };

    pub const Elem = struct {
        pattern: *const Pattern,
        default: ?*const Expr,
        span: Span,
    };

    pub const Prop = struct {
        key: PropertyKey,
        pattern: *const Pattern,
        default: ?*const Expr,
        shorthand: bool,
        span: Span,
    };
};

pub const Expr = struct {
    span: Span,
    /// 1 + depth of the deepest child; bounded by Limits.max_nesting_depth, so every
    /// recursive walk over the tree has bounded native stack use.
    depth: u16,
    /// True if this node (or a nested array/object literal) contains a CoverInitializedName
    /// `{ a = 1 }`, which is a SyntaxError unless reinterpreted as a pattern.
    has_cover_init: bool = false,
    /// True if this node (or a nested array literal) contains a hole `[a, , b]`, which
    /// is Unsupported(sparse_array) unless reinterpreted as a pattern.
    has_hole: bool = false,
    /// True if an array/object literal ends with `...rest,`, which is a SyntaxError
    /// when reinterpreted as a pattern.
    has_rest_trailing_comma: bool = false,
    data: Data,

    pub const Call = struct { callee: *const Expr, args: []const *const Expr };
    pub const Template = struct {
        /// `quasis.len == exprs.len + 1`.
        quasis: []const []const u16,
        exprs: []const *const Expr,
    };
    pub const TaggedTemplate = struct {
        callee: *const Expr,
        /// `cooked.len == raw.len == exprs.len + 1`; invalid escapes in tagged
        /// templates yield `null` (`undefined` in JS) in `cooked`.
        cooked: []const ?[]const u16,
        raw: []const []const u16,
        exprs: []const *const Expr,
    };

    pub const Data = union(enum) {
        number: f64,
        /// UTF-16 code units, possibly containing lone surrogates (DESIGN_DECISIONS D6).
        string: []const u16,
        /// `/pattern/flags` literal (M30, D61).
        regexp: struct { pattern: []const u16, flags: []const u8 },
        template: Template,
        tagged_template: TaggedTemplate,
        boolean: bool,
        null,
        identifier: Ref,
        unary: struct { op: UnaryOp, operand: *const Expr },
        binary: struct { op: BinaryOp, lhs: *const Expr, rhs: *const Expr },
        conditional: struct { cond: *const Expr, then_expr: *const Expr, else_expr: *const Expr },
        /// `target = value` (`plain`), `target op= value` (`compound`), or logical assignment.
        assign: struct { op: AssignOp, target: Target, value: *const Expr },
        /// `pattern = value` destructuring assignment (M26).
        assign_pattern: struct { pattern: *const Pattern, value: *const Expr },
        /// `...expr` inside array literals or call arguments (M26).
        spread: *const Expr,
        /// Elision hole inside an array literal cover grammar; only valid in patterns.
        hole,
        /// `callee(args)`. A member callee (`o.f(…)`) is a method call: `this` is `o`.
        call: Call,
        /// `new callee(args)` or `new callee`.
        new_call: Call,
        /// `++x`, `--x`, `x++`, `x--`.
        update: struct { op: enum { inc, dec }, prefix: bool, target: Target },
        member: Member,
        optional_chain: OptionalChain,
        /// `{ key: value, … }`, in source order.
        object: []const PropertyDef,
        /// `[a, b, …]` (no holes: the parser rejects them).
        array: []const *const Expr,
        /// `delete object.name` / `delete object[expr]`.
        delete: Member,
        /// `delete a?.b` / `delete a?.[k]` (last step is `.prop` or `.elem`).
        delete_optional: OptionalChain,
        /// `this`, only inside functions (at script level: Unsupported).
        this,
        /// `await operand` inside an async function body (M28).
        await: *const Expr,
        /// `function [name](params) { body }` as an expression.
        function: *const Function,
        /// `class [Name] [extends Expr] { ... }` as an expression (M33, D63).
        class: *const Class,
        /// `super(args...)` inside a derived constructor.
        super_call: []const *const Expr,
        /// `super.prop` or `super[expr]` inside a class method/constructor.
        super_member: PropertyKey,
        /// `delete super.prop` / `delete super[expr]` (throws ReferenceError at runtime).
        delete_super,
    };
};

pub const ClassMethod = struct {
    key: PropertyKey,
    is_static: bool,
    func: *const Function,
    span: Span,
};

pub const Class = struct {
    span: Span,
    id: u32,
    kind: enum { declaration, expression },
    name: ?Declarator,
    super_class: ?*const Expr,
    constructor: *const Function,
    methods: []const ClassMethod,
};

/// A function parameter (M26: pattern, optional default, optional rest).
pub const Param = struct {
    pattern: *const Pattern,
    default: ?*const Expr,
    is_rest: bool,
    span: Span,
};

/// A function declaration or expression (M6).
pub const Function = struct {
    span: Span,
    /// Index into `Resolution.functions`; 0 is the script itself, so functions count from 1.
    id: u32,
    kind: enum { declaration, expression },
    is_arrow: bool = false,
    is_async: bool = false,
    /// Concise object-literal method (`{ m() {} }`): not constructable and has no `.prototype` (D62).
    is_method: bool = false,
    /// Class constructor (`class C { constructor() {} }`): requires `new` (D63).
    is_class_constructor: bool = false,
    /// Derived class constructor (`extends`): `super()` allowed, `this` starts in TDZ (D63).
    has_super_ctor: bool = false,
    /// Class method or constructor: `super.prop` allowed via `[[HomeObject]]` (D63).
    has_home_object: bool = false,
    /// Number of parameters before the first default or rest parameter (`F.length`, D62).
    length: u16 = 0,
    /// Required for declarations (bound in the enclosing scope); optional for
    /// expressions (bound only inside the function, DESIGN_DECISIONS D36).
    name: ?Declarator,
    /// Contextually inferred `.name` for anonymous functions/arrows/methods (D62).
    inferred_name: []const u8 = "",
    params: []const Param,
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

pub const DeclItem = struct {
    pattern: *const Pattern,
    init: ?*const Expr,
    span: Span,
};

pub const Declaration = struct {
    kind: DeclKind,
    declarators: []const DeclItem,
};

pub const Stmt = struct {
    span: Span,
    data: Data,

    pub const Call = struct { callee: *const Expr, args: []const *const Expr };

    pub const Data = union(enum) {
        empty,
        expression: *const Expr,
        declaration: Declaration,
        class: *const Class,
        block: []const Stmt,
        @"if": struct { cond: *const Expr, then: *const Stmt, @"else": ?*const Stmt },
        @"while": struct { cond: *const Expr, body: *const Stmt },
        do_while: struct { body: *const Stmt, cond: *const Expr },
        @"switch": struct { discriminant: *const Expr, cases: []const SwitchCase },
        /// The head declaration (if any) lives in its own scope around the body. Its
        /// bindings are the ones the spec copies per iteration (DESIGN_DECISIONS D22).
        @"for": struct { init: ?ForInit, cond: ?*const Expr, update: ?*const Expr, body: *const Stmt },
        for_of: struct { target: ForOfTarget, iterable: *const Expr, body: *const Stmt },
        labeled: struct { label: []const u8, body: *const Stmt },
        @"break": ?[]const u8,
        @"continue": ?[]const u8,
        /// Only at the top level of a script or a function body (blocks: Unsupported).
        function: *const Function,
        /// `return [value];`, only inside a function.
        @"return": ?*const Expr,
        throw: *const Expr,
        @"try": struct {
            body: []const Stmt,
            catch_param: ?*const Pattern,
            catch_body: ?[]const Stmt,
            finally_body: ?[]const Stmt,
        },
    };
};

pub const SwitchCase = struct {
    /// null for `default:`.
    test_expr: ?*const Expr,
    body: []const Stmt,
};

pub const ForInit = union(enum) {
    declaration: Declaration,
    expression: *const Expr,
};

pub const ForOfTarget = union(enum) {
    declaration: struct { kind: DeclKind, pattern: *const Pattern },
    target: *const Pattern,
};

pub const Script = struct {
    statements: []const Stmt,
    /// Number of `Ref`s and `Declarator`s, so the resolver can size its tables exactly.
    ref_count: u32,
    binding_count: u32,
    /// Number of functions plus one (the script is function 0).
    function_count: u32,
};
