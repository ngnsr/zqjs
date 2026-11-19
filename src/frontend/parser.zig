//! Pratt parser for the M1 grammar (LANGUAGE.md §4).
//!
//! Besides building the AST, the parser's main job is *classifying* failures
//! (LANGUAGE.md §1): `SyntaxError` only when no JavaScript parser could accept the
//! input, `Unsupported` for anything that might be valid JavaScript outside ZQJS.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Lexer = @import("lexer.zig").Lexer;
const number = @import("number.zig");
const token = @import("token.zig");
const Token = token.Token;
const Tag = token.Tag;
const diag_mod = @import("diag.zig");
const Diagnostic = diag_mod.Diagnostic;
const Feature = diag_mod.Feature;
const Limits = @import("../limits.zig").Limits;
const regex = @import("../regex.zig");

pub const Error = error{ SyntaxError, Unsupported, LimitExceeded, OutOfMemory };

/// Parses a whole script. `arena` must be an arena-style allocator: nodes are never
/// freed individually; the caller frees everything at once, also after an error.
pub const ParseOptions = struct {
    allow_top_level_await: bool = false,
};

/// On any error other than OutOfMemory, `diag` describes the problem.
/// The returned AST borrows names from `source`.
pub fn parse(arena: Allocator, source: []const u8, limits: Limits, diag: *Diagnostic) Error!ast.Script {
    return parseWithOptions(arena, source, limits, .{}, diag);
}

pub fn parseWithOptions(arena: Allocator, source: []const u8, limits: Limits, options: ParseOptions, diag: *Diagnostic) Error!ast.Script {
    if (source.len > limits.max_source_bytes) {
        diag.* = .{ .detail = .{ .limit_exceeded = .source_bytes } };
        return error.LimitExceeded;
    }
    var p: Parser = .{
        .lexer = .init(source, diag),
        .arena = arena,
        .limits = limits,
        .tok = undefined,
        .async_ctx = if (options.allow_top_level_await) .body else .none,
    };
    p.tok = try p.lexer.next();

    var statements: std.ArrayList(ast.Stmt) = .empty;
    while (p.tok.tag != .eof) try statements.append(arena, try p.statementListItem(.body));
    return .{
        .statements = statements.items,
        .ref_count = p.ref_count,
        .binding_count = p.binding_count,
        .function_count = p.function_count,
        .has_top_level_await = p.has_top_level_await,
    };
}

const unary_bp = 12;

const Infix = struct { op: ast.BinaryOp, bp: u8, right_assoc: bool = false };

/// Binding powers: a higher number binds tighter.
fn infix(tag: Tag) ?Infix {
    return switch (tag) {
        .pipe_pipe => .{ .op = .logical_or, .bp = 1 },
        .question2 => .{ .op = .nullish, .bp = 1 },
        .amp_amp => .{ .op = .logical_and, .bp = 2 },
        .pipe => .{ .op = .bit_or, .bp = 3 },
        .caret => .{ .op = .bit_xor, .bp = 4 },
        .amp => .{ .op = .bit_and, .bp = 5 },
        .eq3 => .{ .op = .strict_eq, .bp = 6 },
        .neq3 => .{ .op = .strict_ne, .bp = 6 },
        .lt => .{ .op = .lt, .bp = 7 },
        .le => .{ .op = .le, .bp = 7 },
        .gt => .{ .op = .gt, .bp = 7 },
        .ge => .{ .op = .ge, .bp = 7 },
        .shl => .{ .op = .shl, .bp = 8 },
        .shr => .{ .op = .shr, .bp = 8 },
        .ushr => .{ .op = .ushr, .bp = 8 },
        .plus => .{ .op = .add, .bp = 9 },
        .minus => .{ .op = .sub, .bp = 9 },
        .star => .{ .op = .mul, .bp = 10 },
        .slash => .{ .op = .div, .bp = 10 },
        .percent => .{ .op = .mod, .bp = 10 },
        .star_star => .{ .op = .pow, .bp = 11, .right_assoc = true },
        else => null,
    };
}

/// `=` gives `.plain`; compound and logical assignment operators give their kind.
fn assignOp(tag: Tag) ?ast.AssignOp {
    return switch (tag) {
        .eq => .plain,
        .plus_eq => .{ .compound = .add },
        .minus_eq => .{ .compound = .sub },
        .star_eq => .{ .compound = .mul },
        .slash_eq => .{ .compound = .div },
        .percent_eq => .{ .compound = .mod },
        .star_star_eq => .{ .compound = .pow },
        .shl_eq => .{ .compound = .shl },
        .shr_eq => .{ .compound = .shr },
        .ushr_eq => .{ .compound = .ushr },
        .amp_eq => .{ .compound = .bit_and },
        .caret_eq => .{ .compound = .bit_xor },
        .pipe_eq => .{ .compound = .bit_or },
        .amp_amp_eq => .logical_and,
        .pipe_pipe_eq => .logical_or,
        .question2_eq => .nullish,
        else => null,
    };
}

const LabelEntry = struct {
    name: []const u8,
    is_loop: bool,
};

const Parser = struct {
    lexer: Lexer,
    tok: Token,
    arena: Allocator,
    limits: Limits,
    /// Current recursion depth of `statement` + `expression` (both count toward the limit).
    depth: u32 = 0,
    /// Number of enclosing loops *in the current function*; `break`/`continue` are
    /// legal only when > 0 (they cannot cross a function boundary).
    loop_depth: u32 = 0,
    /// Number of enclosing `switch` statements *in the current function*; `break` is
    /// legal when `loop_depth > 0 or switch_depth > 0`.
    switch_depth: u32 = 0,
    /// Active statement labels in the current function/script.
    labels: std.ArrayList(LabelEntry) = .empty,
    /// Number of enclosing functions; `return` is legal only when > 0.
    function_depth: u32 = 0,
    /// Inside a `for (…;` head: `in` is not an operator there (`for (x in o)` is for-in).
    /// Brackets, parentheses and literals turn it back on (`nested`), as in the grammar.
    no_in: bool = false,
    ref_count: u32 = 0,
    binding_count: u32 = 0,
    function_count: u32 = 1, // function 0 is the script
    last_was_paren: bool = false,
    cover_init_span: ast.Span = .{ .start = 0, .end = 0 },
    hole_span: ast.Span = .{ .start = 0, .end = 0 },
    async_ctx: enum { none, params, body } = .none,
    yield_ctx: enum { none, params, body } = .none,
    await_count: u32 = 0,
    /// Parsing a `for await (…` head: `in` there is a SyntaxError (D68).
    for_await_head: bool = false,
    /// Yield expressions parsed so far: arrow parameters must not contain one.
    yield_count: u32 = 0,
    /// When probing `async (...)` at `.none`, defer `await` identifier error until we know if `=>` follows.
    in_async_paren: bool = false,
    async_paren_await_span: ?ast.Span = null,
    in_derived_ctor: enum { none, direct, arrow } = .none,
    in_class_method: bool = false,
    class_count: u32 = 0,
    has_top_level_await: bool = false,

    fn advance(p: *Parser) Error!void {
        p.tok = try p.lexer.next();
    }

    /// One token of lookahead, by lexing from a copy of the lexer. The lexer is a
    /// plain value (source + position), so copying it is a cheap, safe snapshot.
    fn peek(p: *const Parser) Error!Token {
        var copy = p.lexer;
        return copy.next();
    }

    fn source(p: *const Parser) []const u8 {
        return p.lexer.source;
    }

    fn isText(p: *const Parser, t: Token, text: []const u8) bool {
        return t.tag == .identifier and std.mem.eql(u8, t.text(p.source()), text);
    }

    fn enter(p: *Parser) Error!void {
        p.depth += 1;
        if (p.depth > p.limits.max_nesting_depth) return p.limitExceeded(p.tok.start, p.tok.end);
    }

    // ------------------------------------------------------------ statements

    /// A statement where declarations are allowed: script top level, function bodies
    /// (`.body`) and blocks (`.block`). Function declarations only in `.body`: inside
    /// blocks sloppy-mode JS gives them Annex B semantics, which ZQJS doesn't implement.
    fn statementListItem(p: *Parser, context: enum { body, block }) Error!ast.Stmt {
        if (p.isText(p.tok, "function")) {
            if (context == .block) return p.fail(.{ .unsupported = .block_function }, p.tok);
            const t = p.tok;
            const f = try p.function(.declaration, false, t.start);
            return .{ .span = .{ .start = t.start, .end = f.span.end }, .data = .{ .function = f } };
        }
        if (p.isText(p.tok, "async")) {
            const next = try p.peek();
            if (!next.newline_before and p.isText(next, "function")) {
                if (context == .block) return p.fail(.{ .unsupported = .block_function }, p.tok);
                const t = p.tok;
                try p.advance(); // `async`
                const f = try p.function(.declaration, true, t.start);
                return .{ .span = .{ .start = t.start, .end = f.span.end }, .data = .{ .function = f } };
            }
        }
        if (p.isText(p.tok, "class")) {
            const c = try p.parseClass(.declaration);
            return .{ .span = c.span, .data = .{ .class = c } };
        }
        if (p.tok.tag == .kw_const) return p.declarationStatement(.@"const");
        if (p.isText(p.tok, "let") and try p.letStartsDeclaration()) return p.declarationStatement(.let);
        return p.statement();
    }

    /// `let` begins a declaration when followed by a binding name, even on the next
    /// line (`let\nx = 1` declares x), or by `[` / `{` (destructuring). Followed by
    /// anything else, `let` is an ordinary identifier in sloppy JS (`let;`, `let = 1`).
    /// `let in x` / `let instanceof x` are expressions using a variable named `let`.
    fn letStartsDeclaration(p: *Parser) Error!bool {
        const next = try p.peek();
        if (next.tag == .l_bracket or next.tag == .l_brace) return true;
        if (next.tag == .identifier) return !p.isText(next, "in") and !p.isText(next, "instanceof");
        return token.isKeyword(next.tag);
    }

    /// A statement in a position where declarations are not allowed (`if`/loop bodies).
    fn statement(p: *Parser) Error!ast.Stmt {
        try p.enter();
        defer p.depth -= 1;
        const t = p.tok;
        switch (t.tag) {
            .semicolon => {
                try p.advance();
                return .{ .span = span(t, t), .data = .empty };
            },
            .l_brace => return p.block(),
            .kw_if => return p.ifStatement(),
            .kw_while => return p.whileStatement(),
            .kw_for => return p.forStatement(),
            .kw_break, .kw_continue => return p.jumpStatement(),
            .kw_const => return p.fail(.{ .syntax_error = "lexical declaration cannot appear in a single-statement context" }, t),
            else => {},
        }
        // `if (c) function f() {}` is legal sloppy JS (Annex B).
        if (p.isText(t, "function")) return p.fail(.{ .unsupported = .block_function }, t);
        if (p.isText(t, "async")) {
            const next = try p.peek();
            if (!next.newline_before and p.isText(next, "function"))
                return p.fail(.{ .syntax_error = "async function declarations cannot appear in a single-statement context" }, t);
        }
        if (p.isText(t, "return")) return p.returnStatement();
        if (p.isText(t, "throw")) return p.throwStatement();
        if (p.isText(t, "try")) return p.tryStatement();
        if (p.isText(t, "do")) return p.doWhileStatement();
        if (p.isText(t, "switch")) return p.switchStatement();
        if (p.isText(t, "class")) return p.fail(.{ .syntax_error = "class declaration cannot appear in a single-statement context" }, t);
        if (p.isText(t, "let")) {
            const next = try p.peek();
            // `if (c) let x` is an error, but `if (c) let\nx` may be ASI + two statements.
            if (!next.newline_before and (next.tag == .l_bracket or next.tag == .l_brace or
                (next.tag == .identifier and !p.isText(next, "in") and !p.isText(next, "instanceof"))))
                return p.fail(.{ .syntax_error = "lexical declaration cannot appear in a single-statement context" }, t);
            return p.fail(.{ .unsupported = .syntax }, t);
        }
        if (p.tok.tag == .identifier and (try p.peek()).tag == .colon) {
            return p.labeledStatement();
        }
        const e = try p.expression();
        if (p.tok.tag == .colon) return p.fail(.{ .syntax_error = "unexpected ':'" }, p.tok);
        const end = p.tok;
        try p.endStatement();
        return .{ .span = .{ .start = e.span.start, .end = end.end }, .data = .{ .expression = e } };
    }

    fn labeledStatement(p: *Parser) Error!ast.Stmt {
        const start = p.tok.start;
        const saved_len = p.labels.items.len;
        defer p.labels.items.len = saved_len;

        var chain: std.ArrayList([]const u8) = .empty;
        while (p.tok.tag == .identifier and (try p.peek()).tag == .colon) {
            const lbl_tok = p.tok;
            const name = lbl_tok.text(p.source());
            for (p.labels.items) |existing| {
                if (std.mem.eql(u8, existing.name, name)) {
                    return p.fail(.{ .syntax_error = "label has already been declared" }, lbl_tok);
                }
            }
            try p.labels.append(p.arena, .{ .name = name, .is_loop = false });
            try chain.append(p.arena, name);
            try p.advance(); // identifier
            try p.advance(); // `:`
        }
        const is_loop = (p.tok.tag == .kw_while or p.tok.tag == .kw_for or (p.tok.tag == .identifier and p.isText(p.tok, "do")));
        for (p.labels.items[saved_len..]) |*entry| entry.is_loop = is_loop;

        var body = try p.boxed(try p.statement());
        var i = chain.items.len;
        while (i > 0) {
            i -= 1;
            const lbl = chain.items[i];
            if (i == 0) {
                return .{ .span = .{ .start = start, .end = body.span.end }, .data = .{ .labeled = .{ .label = lbl, .body = body } } };
            }
            body = try p.boxed(.{ .span = body.span, .data = .{ .labeled = .{ .label = lbl, .body = body } } });
        }
        unreachable;
    }

    fn declarationStatement(p: *Parser, kind: ast.DeclKind) Error!ast.Stmt {
        const start = p.tok.start;
        const decl = try p.declaration(kind, false);
        const end = p.tok;
        try p.endStatement();
        return .{ .span = .{ .start = start, .end = end.end }, .data = .{ .declaration = decl } };
    }

    /// `let|const pattern [= init] (, pattern [= init])*` without the terminator.
    fn declaration(p: *Parser, kind: ast.DeclKind, allow_for_of: bool) Error!ast.Declaration {
        try p.advance(); // `let` / `const`
        var list: std.ArrayList(ast.DeclItem) = .empty;
        while (true) {
            const start_tok = p.tok;
            const pat = try p.parseBindingPattern(true);
            if (p.isText(p.tok, "in")) {
                if (p.for_await_head) return p.fail(.{ .syntax_error = "for await requires 'of'" }, p.tok);
                if (!allow_for_of or list.items.len > 0) return p.fail(.{ .syntax_error = "invalid for-in declaration" }, p.tok);
                try list.append(p.arena, .{ .pattern = pat, .init = null, .span = pat.span });
                return .{ .kind = kind, .declarators = list.items };
            }
            if (p.isText(p.tok, "of")) {
                if (!allow_for_of or list.items.len > 0) return p.fail(.{ .syntax_error = "invalid for-of declaration" }, p.tok);
                try list.append(p.arena, .{ .pattern = pat, .init = null, .span = pat.span });
                return .{ .kind = kind, .declarators = list.items };
            }
            var init: ?*const ast.Expr = null;
            if (p.tok.tag == .eq) {
                try p.advance();
                init = try p.assignment();
                if (pat.data == .binding) inferExprName(init.?, pat.data.binding.name);
            } else if (kind == .@"const") {
                return p.fail(.{ .syntax_error = "missing initializer in const declaration" }, start_tok);
            } else if (pat.data != .binding) {
                return p.fail(.{ .syntax_error = "missing initializer in destructuring declaration" }, start_tok);
            }
            const end_pos = if (init) |e| e.span.end else pat.span.end;
            try list.append(p.arena, .{ .pattern = pat, .init = init, .span = .{ .start = pat.span.start, .end = end_pos } });
            if (p.tok.tag != .comma) break;
            try p.advance();
        }
        return .{ .kind = kind, .declarators = list.items };
    }

    fn block(p: *Parser) Error!ast.Stmt {
        const open = p.tok;
        try p.advance();
        var list: std.ArrayList(ast.Stmt) = .empty;
        while (p.tok.tag != .r_brace) {
            if (p.tok.tag == .eof) return p.fail(.{ .syntax_error = "unterminated block" }, open);
            try list.append(p.arena, try p.statementListItem(.block));
        }
        const close = p.tok;
        try p.advance();
        return .{ .span = span(open, close), .data = .{ .block = list.items } };
    }

    /// `(` Expression `)`, as used by `if` and `while`.
    fn condition(p: *Parser) Error!*const ast.Expr {
        if (p.tok.tag != .l_paren) return p.fail(.{ .syntax_error = "expected '('" }, p.tok);
        try p.advance();
        const cond = try p.expression();
        try p.expectAfterExpression(.r_paren);
        return cond;
    }

    fn ifStatement(p: *Parser) Error!ast.Stmt {
        const start = p.tok.start;
        try p.advance();
        const cond = try p.condition();
        const then = try p.boxed(try p.statement());
        var @"else": ?*const ast.Stmt = null;
        if (p.tok.tag == .kw_else) {
            try p.advance();
            @"else" = try p.boxed(try p.statement());
        }
        const end = (@"else" orelse then).span.end;
        return .{ .span = .{ .start = start, .end = end }, .data = .{ .@"if" = .{ .cond = cond, .then = then, .@"else" = @"else" } } };
    }

    fn whileStatement(p: *Parser) Error!ast.Stmt {
        const start = p.tok.start;
        try p.advance();
        const cond = try p.condition();
        const body = try p.loopBody();
        return .{ .span = .{ .start = start, .end = body.span.end }, .data = .{ .@"while" = .{ .cond = cond, .body = body } } };
    }

    fn forStatement(p: *Parser) Error!ast.Stmt {
        const start = p.tok.start;
        try p.advance();
        var is_await = false;
        if (p.isText(p.tok, "await")) {
            // `for await` (D68): only directly in async functions; scripts have no top-level await (D56).
            if (p.async_ctx != .body) {
                if (p.function_depth == 0) return p.fail(.{ .unsupported = .syntax }, p.tok);
                return p.fail(.{ .syntax_error = "for await is only valid in async functions" }, p.tok);
            }
            is_await = true;
            if (p.function_depth == 0) p.has_top_level_await = true;
            try p.advance();
        }
        if (p.tok.tag != .l_paren) {
            // `for x` is not valid JS, but we needn't be precise.
            return p.fail(.{ .unsupported = .syntax }, p.tok);
        }
        try p.advance();

        var init: ?ast.ForInit = null;
        p.no_in = true;
        p.for_await_head = is_await;
        if (p.tok.tag == .kw_const) {
            init = .{ .declaration = try p.declaration(.@"const", true) };
        } else if (p.isText(p.tok, "let") and try p.letStartsDeclaration()) {
            init = .{ .declaration = try p.declaration(.let, true) };
        } else if (p.tok.tag != .semicolon) {
            init = .{ .expression = try p.expression() };
        }
        p.no_in = false;
        p.for_await_head = false;
        if (p.isText(p.tok, "in")) {
            if (is_await) return p.fail(.{ .syntax_error = "for await requires 'of'" }, p.tok);
            const target = try p.extractForEachTarget(init, "for-in");
            try p.advance();
            const obj_expr = try p.expression();
            try p.expectAfterExpression(.r_paren);
            const body = try p.loopBody();
            return .{ .span = .{ .start = start, .end = body.span.end }, .data = .{ .for_in = .{ .target = target, .object = obj_expr, .body = body } } };
        }
        if (p.isText(p.tok, "of")) {
            const target = try p.extractForEachTarget(init, "for-of");
            try p.advance();
            const iterable = try p.expression();
            try p.expectAfterExpression(.r_paren);
            const body = try p.loopBody();
            return .{ .span = .{ .start = start, .end = body.span.end }, .data = .{ .for_of = .{ .target = target, .iterable = iterable, .body = body, .is_await = is_await } } };
        }
        if (is_await) return p.fail(.{ .syntax_error = "for await requires 'of'" }, p.tok);
        try p.expectAfterExpression(.semicolon);

        const cond = if (p.tok.tag == .semicolon) null else try p.expression();
        try p.expectAfterExpression(.semicolon);
        const update = if (p.tok.tag == .r_paren) null else try p.expression();
        try p.expectAfterExpression(.r_paren);

        const body = try p.loopBody();
        return .{ .span = .{ .start = start, .end = body.span.end }, .data = .{ .@"for" = .{ .init = init, .cond = cond, .update = update, .body = body } } };
    }

    fn extractForEachTarget(p: *Parser, init: ?ast.ForInit, comptime kind: []const u8) Error!ast.ForOfTarget {
        return switch (init orelse return p.fail(.{ .syntax_error = "missing left-hand side in " ++ kind }, p.tok)) {
            .declaration => |decl| blk: {
                if (decl.declarators.len != 1 or decl.declarators[0].init != null)
                    return p.fail(.{ .syntax_error = kind ++ " loop variable declaration may not have an initializer" }, p.tok);
                break :blk .{ .declaration = .{ .kind = decl.kind, .pattern = decl.declarators[0].pattern } };
            },
            .expression => |e| blk: {
                if (e.data == .array or e.data == .object) {
                    if (p.last_was_paren) return p.failAt(.{ .syntax_error = "invalid left-hand side in " ++ kind }, e.span.start, e.span.end);
                    break :blk .{ .target = try p.exprToAssignPattern(e) };
                }
                try p.rejectCoverExpr(e);
                const t = try p.assignTarget(e, "invalid left-hand side in " ++ kind);
                break :blk .{ .target = try p.patNode(e.span, .{ .target = t }, 0) };
            },
        };
    }

    fn loopBody(p: *Parser) Error!*const ast.Stmt {
        p.loop_depth += 1;
        defer p.loop_depth -= 1;
        return p.boxed(try p.statement());
    }

    fn jumpStatement(p: *Parser) Error!ast.Stmt {
        const t = p.tok;
        try p.advance();
        var label: ?[]const u8 = null;
        if (p.tok.tag == .identifier and !p.tok.newline_before) {
            const name = p.tok.text(p.source());
            var found: ?LabelEntry = null;
            var i = p.labels.items.len;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, p.labels.items[i].name, name)) {
                    found = p.labels.items[i];
                    break;
                }
            }
            const entry = found orelse return p.fail(.{ .syntax_error = "undefined label" }, p.tok);
            if (t.tag == .kw_continue and !entry.is_loop) {
                return p.fail(.{ .syntax_error = "illegal continue statement: label does not denote an iteration statement" }, p.tok);
            }
            label = name;
            try p.advance();
        } else if (t.tag == .kw_break) {
            if (p.loop_depth == 0 and p.switch_depth == 0)
                return p.fail(.{ .syntax_error = "'break' outside a loop or switch" }, t);
        } else if (p.loop_depth == 0) {
            return p.fail(.{ .syntax_error = "'continue' outside a loop" }, t);
        }
        const end = p.tok;
        try p.endStatement();
        return .{ .span = span(t, end), .data = if (t.tag == .kw_break) .{ .@"break" = label } else .{ .@"continue" = label } };
    }

    fn doWhileStatement(p: *Parser) Error!ast.Stmt {
        const start = p.tok.start;
        try p.advance(); // `do`
        const body = try p.loopBody();
        if (p.tok.tag != .kw_while) return p.fail(.{ .syntax_error = "expected 'while'" }, p.tok);
        try p.advance(); // `while`
        const cond = try p.condition();
        const end = p.tok;
        // ES6+ unconditionally inserts `;` after `do ... while (cond)` even without a
        // newline, so only tokens that cannot start a statement are SyntaxErrors.
        if (p.tok.tag == .semicolon) {
            try p.advance();
        } else {
            const certain = switch (p.tok.tag) {
                .r_paren, .r_bracket, .comma, .colon, .eq, .star, .star_star, .percent, .eq3, .neq3, .eq2, .neq2, .lt, .le, .gt, .ge, .amp_amp, .pipe_pipe, .question2, .question, .question_dot, .arrow, .plus_eq, .minus_eq, .star_eq, .percent_eq, .star_star_eq, .shl_eq, .shr_eq, .ushr_eq, .amp_eq, .pipe_eq, .caret_eq, .amp_amp_eq, .pipe_pipe_eq, .question2_eq => true,
                else => false,
            };
            if (certain) return p.fail(.{ .syntax_error = "unexpected token after do-while" }, p.tok);
            return p.fail(.{ .unsupported = .asi }, p.tok);
        }
        return .{ .span = .{ .start = start, .end = end.end }, .data = .{ .do_while = .{ .body = body, .cond = cond } } };
    }

    fn switchStatement(p: *Parser) Error!ast.Stmt {
        const start = p.tok.start;
        try p.advance(); // `switch`
        const discriminant = try p.condition();
        const open = p.tok;
        if (open.tag != .l_brace) return p.fail(.{ .syntax_error = "expected '{'" }, open);
        try p.advance();

        p.switch_depth += 1;
        defer p.switch_depth -= 1;

        var cases: std.ArrayList(ast.SwitchCase) = .empty;
        var has_default = false;
        while (p.tok.tag != .r_brace) {
            if (p.tok.tag == .eof) return p.fail(.{ .syntax_error = "unterminated switch statement" }, open);
            var test_expr: ?*const ast.Expr = null;
            if (p.isText(p.tok, "case")) {
                try p.advance();
                test_expr = try p.expression();
                if (p.tok.tag != .colon) return p.fail(.{ .syntax_error = "expected ':'" }, p.tok);
                try p.advance();
            } else if (p.isText(p.tok, "default")) {
                if (has_default) return p.fail(.{ .syntax_error = "more than one default clause in switch" }, p.tok);
                has_default = true;
                try p.advance();
                if (p.tok.tag != .colon) return p.fail(.{ .syntax_error = "expected ':'" }, p.tok);
                try p.advance();
            } else {
                return p.fail(.{ .syntax_error = "expected 'case' or 'default'" }, p.tok);
            }
            var body: std.ArrayList(ast.Stmt) = .empty;
            while (p.tok.tag != .r_brace and p.tok.tag != .eof and !p.isText(p.tok, "case") and !p.isText(p.tok, "default")) {
                try body.append(p.arena, try p.statementListItem(.block));
            }
            try cases.append(p.arena, .{ .test_expr = test_expr, .body = body.items });
        }
        const close = p.tok;
        try p.advance();
        return .{ .span = .{ .start = start, .end = close.end }, .data = .{ .@"switch" = .{ .discriminant = discriminant, .cases = cases.items } } };
    }

    /// `return;` / `return value;`. A line break after `return` means ASI (`return;`),
    /// reported as Unsupported like any other ASI.
    fn returnStatement(p: *Parser) Error!ast.Stmt {
        const t = p.tok;
        if (p.function_depth == 0) return p.fail(.{ .syntax_error = "'return' outside a function" }, t);
        try p.advance();
        if (p.tok.tag == .semicolon) {
            const end = p.tok;
            try p.advance();
            return .{ .span = span(t, end), .data = .{ .@"return" = null } };
        }
        if (p.tok.newline_before or p.tok.tag == .eof or p.tok.tag == .r_brace) return p.fail(.{ .unsupported = .asi }, p.tok);
        const value = try p.expression();
        const end = p.tok;
        try p.endStatement();
        return .{ .span = span(t, end), .data = .{ .@"return" = value } };
    }

    /// `throw value;`. A line break after `throw` is a SyntaxError (`[no LineTerminator here]`).
    fn throwStatement(p: *Parser) Error!ast.Stmt {
        const t = p.tok;
        try p.advance();
        if (p.tok.newline_before) return p.fail(.{ .syntax_error = "illegal newline after throw" }, p.tok);
        if (p.tok.tag == .semicolon or p.tok.tag == .eof or p.tok.tag == .r_brace) {
            return p.fail(.{ .syntax_error = "expected expression after throw" }, p.tok);
        }
        const value = try p.expression();
        const end = p.tok;
        try p.endStatement();
        return .{ .span = span(t, end), .data = .{ .throw = value } };
    }

    /// `try { ... } [catch [(e)] { ... }] [finally { ... }]`.
    fn tryStatement(p: *Parser) Error!ast.Stmt {
        const start = p.tok.start;
        try p.advance(); // `try`
        if (p.tok.tag != .l_brace) return p.fail(.{ .syntax_error = "expected '{' after try" }, p.tok);
        const try_blk = try p.block();
        var end = try_blk.span.end;
        var param: ?*const ast.Pattern = null;
        var catch_body: ?[]const ast.Stmt = null;
        if (p.isText(p.tok, "catch")) {
            try p.advance(); // `catch`
            if (p.tok.tag == .l_paren) {
                try p.advance();
                param = try p.parseBindingPattern(false);
                if (p.tok.tag != .r_paren) return p.fail(.{ .syntax_error = "expected ')' after catch parameter" }, p.tok);
                try p.advance();
            }
            if (p.tok.tag != .l_brace) return p.fail(.{ .syntax_error = "expected '{' after catch" }, p.tok);
            const catch_blk = try p.block();
            catch_body = catch_blk.data.block;
            end = catch_blk.span.end;
        }
        var finally_body: ?[]const ast.Stmt = null;
        if (p.isText(p.tok, "finally")) {
            try p.advance(); // `finally`
            if (p.tok.tag != .l_brace) return p.fail(.{ .syntax_error = "expected '{' after finally" }, p.tok);
            const finally_blk = try p.block();
            finally_body = finally_blk.data.block;
            end = finally_blk.span.end;
        }
        if (catch_body == null and finally_body == null) {
            return p.fail(.{ .syntax_error = "missing catch or finally after try" }, p.tok);
        }
        return .{
            .span = .{ .start = start, .end = end },
            .data = .{ .@"try" = .{ .body = try_blk.data.block, .catch_param = param, .catch_body = catch_body, .finally_body = finally_body } },
        };
    }

    /// `function [*][name](a, b, …) { body }`, starting at `function`.
    fn function(p: *Parser, kind: @FieldType(ast.Function, "kind"), is_async: bool, start: u32) Error!*const ast.Function {
        try p.enter();
        defer p.depth -= 1;
        try p.advance(); // `function`
        var is_generator = false;
        if (p.tok.tag == .star) {
            is_generator = true;
            try p.advance();
        }

        const outer_async_ctx = p.async_ctx;
        const outer_yield_ctx = p.yield_ctx;
        defer {
            p.async_ctx = outer_async_ctx;
            p.yield_ctx = outer_yield_ctx;
        }
        if (is_async and kind == .expression) p.async_ctx = .params;
        if (is_generator and kind == .expression) p.yield_ctx = .params;

        var name: ?ast.Declarator = null;
        if (p.tok.tag != .l_paren) {
            name = try p.bindingName(false);
        } else if (kind == .declaration) {
            return p.fail(.{ .syntax_error = "function declaration needs a name" }, p.tok);
        }
        return p.functionRest(start, kind, name, is_async, is_generator);
    }

    /// From the parameter list on: shared by `function` and object-literal methods
    /// (`{ f(a) { … } }`, an anonymous function expression whose name is not bound).
    fn functionRest(p: *Parser, start: u32, kind: @FieldType(ast.Function, "kind"), name: ?ast.Declarator, is_async: bool, is_generator: bool) Error!*const ast.Function {
        const id = p.function_count;
        p.function_count += 1;

        const outer_async_ctx = p.async_ctx;
        const outer_yield_ctx = p.yield_ctx;
        p.async_ctx = if (is_async) .params else .none;
        p.yield_ctx = if (is_generator) .params else .none;
        defer {
            p.async_ctx = outer_async_ctx;
            p.yield_ctx = outer_yield_ctx;
        }

        const params = try p.parseParams();

        if (p.tok.tag != .l_brace) return p.fail(.{ .syntax_error = "expected '{'" }, p.tok);
        const outer_loops = p.loop_depth;
        const outer_switches = p.switch_depth;
        const outer_labels = p.labels;
        const outer_derived = p.in_derived_ctor;
        const outer_method = p.in_class_method;
        p.loop_depth = 0;
        p.switch_depth = 0;
        p.labels = .empty;
        p.in_derived_ctor = .none;
        p.in_class_method = false;
        p.function_depth += 1;
        p.async_ctx = if (is_async) .body else .none;
        p.yield_ctx = if (is_generator) .body else .none;
        defer {
            p.loop_depth = outer_loops;
            p.switch_depth = outer_switches;
            p.labels = outer_labels;
            p.in_derived_ctor = outer_derived;
            p.in_class_method = outer_method;
            p.function_depth -= 1;
        }
        const parsed_body = try p.parseFunctionBody();

        const f = try p.arena.create(ast.Function);
        f.* = .{
            .span = .{ .start = start, .end = parsed_body.end },
            .id = id,
            .kind = kind,
            .is_async = is_async,
            .is_generator = is_generator,
            .length = paramLength(params),
            .name = name,
            .params = params,
            .body = parsed_body.body,
        };
        return f;
    }

    fn parseParams(p: *Parser) Error![]const ast.Param {
        if (p.tok.tag != .l_paren) return p.fail(.{ .syntax_error = "expected '('" }, p.tok);
        try p.advance();
        var params: std.ArrayList(ast.Param) = .empty;
        while (p.tok.tag != .r_paren) {
            const p_start = p.tok.start;
            if (p.tok.tag == .ellipsis) {
                try p.advance();
                const pat = try p.parseBindingPattern(false);
                if (p.tok.tag == .eq) return p.fail(.{ .syntax_error = "rest parameter may not have a default initializer" }, p.tok);
                if (p.tok.tag == .comma) return p.fail(.{ .syntax_error = "rest parameter must be last formal parameter" }, p.tok);
                try params.append(p.arena, .{ .pattern = pat, .default = null, .is_rest = true, .span = .{ .start = p_start, .end = pat.span.end } });
                break;
            }
            const pat = try p.parseBindingPattern(false);
            var default: ?*const ast.Expr = null;
            if (p.tok.tag == .eq) {
                try p.advance();
                default = try p.nestedAssignment();
                if (pat.data == .binding) inferExprName(default.?, pat.data.binding.name);
            }
            const p_end = if (default) |d| d.span.end else pat.span.end;
            try params.append(p.arena, .{ .pattern = pat, .default = default, .is_rest = false, .span = .{ .start = p_start, .end = p_end } });
            if (p.tok.tag != .comma) break;
            try p.advance(); // a trailing comma is allowed: `function f(a,) {}`
        }
        try p.expectAfterExpression(.r_paren);
        return params.items;
    }

    fn parseFunctionBody(p: *Parser) Error!struct { body: []const ast.Stmt, end: u32 } {
        const open = p.tok;
        try p.advance();
        const saved_no_in = p.no_in;
        p.no_in = false;
        defer p.no_in = saved_no_in;
        var body: std.ArrayList(ast.Stmt) = .empty;
        while (p.tok.tag != .r_brace) {
            if (p.tok.tag == .eof) return p.fail(.{ .syntax_error = "unterminated function body" }, open);
            try body.append(p.arena, try p.statementListItem(.body));
        }
        const close = p.tok;
        try p.advance();
        return .{ .body = body.items, .end = close.end };
    }

    /// A function or parameter name. Reserved words are SyntaxErrors; `let` is a legal
    /// sloppy-mode name ZQJS doesn't support (unless inside let/const, where it's a SyntaxError);
    /// `arguments` would shadow the arguments object.
    fn bindingName(p: *Parser, is_lexical_decl: bool) Error!ast.Declarator {
        const t = p.tok;
        const name = t.text(p.source());
        if (t.tag != .identifier and !token.isKeyword(t.tag)) return p.fail(.{ .unsupported = .syntax }, t);
        if (token.isKeyword(t.tag) or token.reserved_identifiers.has(name))
            return p.fail(.{ .syntax_error = "reserved word cannot be a binding name" }, t);
        if (std.mem.eql(u8, name, "let")) {
            if (is_lexical_decl) return p.fail(.{ .syntax_error = "let is disallowed as a lexically bound name" }, t);
            return p.fail(.{ .unsupported = .syntax }, t);
        }
        if (std.mem.eql(u8, name, "arguments")) return p.fail(.{ .unsupported = .arguments }, t);
        if (std.mem.eql(u8, name, "await")) {
            return switch (p.async_ctx) {
                .none => p.fail(.{ .unsupported = .syntax }, t),
                .params, .body => p.fail(.{ .syntax_error = "'await' is not a valid identifier name in an async function" }, t),
            };
        }
        if (std.mem.eql(u8, name, "yield") and p.yield_ctx != .none) {
            return p.fail(.{ .syntax_error = "'yield' is not a valid identifier name in a generator" }, t);
        }
        try p.advance();
        const d: ast.Declarator = .{ .name = name, .span = span(t, t), .binding = p.binding_count, .init = null };
        p.binding_count += 1;
        return d;
    }

    fn parseBindingPattern(p: *Parser, is_lexical_decl: bool) Error!*const ast.Pattern {
        try p.enter();
        defer p.depth -= 1;
        return switch (p.tok.tag) {
            .l_bracket => p.parseArrayBindingPattern(is_lexical_decl),
            .l_brace => p.parseObjectBindingPattern(is_lexical_decl),
            else => {
                const d = try p.bindingName(is_lexical_decl);
                return p.patNode(d.span, .{ .binding = d }, 0);
            },
        };
    }

    fn parseArrayBindingPattern(p: *Parser, is_lexical_decl: bool) Error!*const ast.Pattern {
        const open = p.tok;
        try p.advance();
        var elems: std.ArrayList(?ast.Pattern.Elem) = .empty;
        var rest: ?*const ast.Pattern = null;
        var max_depth: u16 = 0;
        while (p.tok.tag != .r_bracket) {
            if (p.tok.tag == .eof) return p.fail(.{ .syntax_error = "unterminated array pattern" }, open);
            if (p.tok.tag == .comma) {
                try elems.append(p.arena, null);
                try p.advance();
                continue;
            }
            if (p.tok.tag == .ellipsis) {
                try p.advance();
                const r = try p.parseBindingPattern(is_lexical_decl);
                max_depth = @max(max_depth, r.depth);
                if (p.tok.tag == .eq) return p.fail(.{ .syntax_error = "rest element may not have a default initializer" }, p.tok);
                if (p.tok.tag == .comma) return p.fail(.{ .syntax_error = "rest element must be last element" }, p.tok);
                if (p.tok.tag != .r_bracket) return p.fail(.{ .syntax_error = "expected ']' after rest element" }, p.tok);
                rest = r;
                break;
            }
            const pat = try p.parseBindingPattern(is_lexical_decl);
            max_depth = @max(max_depth, pat.depth);
            var default: ?*const ast.Expr = null;
            if (p.tok.tag == .eq) {
                try p.advance();
                default = try p.nestedAssignment();
                max_depth = @max(max_depth, default.?.depth);
                if (pat.data == .binding) inferExprName(default.?, pat.data.binding.name);
            }
            const end_pos = if (default) |d| d.span.end else pat.span.end;
            try elems.append(p.arena, .{ .pattern = pat, .default = default, .span = .{ .start = pat.span.start, .end = end_pos } });
            if (p.tok.tag != .comma) break;
            try p.advance();
        }
        const close = p.tok;
        if (close.tag != .r_bracket) return p.fail(.{ .syntax_error = "expected ']'" }, close);
        try p.advance();
        return p.patNode(span(open, close), .{ .array = .{ .elems = elems.items, .rest = rest } }, max_depth);
    }

    fn parseObjectBindingPattern(p: *Parser, is_lexical_decl: bool) Error!*const ast.Pattern {
        const open = p.tok;
        try p.advance();
        var props: std.ArrayList(ast.Pattern.Prop) = .empty;
        var rest: ?*const ast.Pattern = null;
        var max_depth: u16 = 0;
        while (p.tok.tag != .r_brace) {
            const t = p.tok;
            if (t.tag == .eof) return p.fail(.{ .syntax_error = "unterminated object pattern" }, open);
            if (t.tag == .ellipsis) {
                try p.advance();
                if (p.tok.tag == .l_brace or p.tok.tag == .l_bracket)
                    return p.fail(.{ .syntax_error = "rest element must be an identifier" }, p.tok);
                const d = try p.bindingName(is_lexical_decl);
                const r = try p.patNode(d.span, .{ .binding = d }, 0);
                max_depth = @max(max_depth, r.depth);
                if (p.tok.tag == .eq) return p.fail(.{ .syntax_error = "rest element may not have a default initializer" }, p.tok);
                if (p.tok.tag == .comma) return p.fail(.{ .syntax_error = "rest element must be last element" }, p.tok);
                if (p.tok.tag != .r_brace) return p.fail(.{ .syntax_error = "expected '}' after rest element" }, p.tok);
                rest = r;
                break;
            }
            const k: ast.PropertyKey = switch (t.tag) {
                .l_bracket => blk: {
                    try p.advance();
                    const e = try p.nested();
                    try p.expectAfterExpression(.r_bracket);
                    max_depth = @max(max_depth, e.depth);
                    break :blk .{ .computed = e };
                },
                .string => blk: {
                    const units = try p.decodeString(t);
                    try p.advance();
                    break :blk .{ .string = units };
                },
                .number => blk: {
                    const n = try number.literalValue(p.arena, t.text(p.source()));
                    try p.advance();
                    break :blk .{ .number = n };
                },
                else => blk: {
                    if (t.tag != .identifier and !token.isKeyword(t.tag)) return p.fail(.{ .syntax_error = "unexpected token in object pattern" }, t);
                    try p.advance();
                    break :blk .{ .name = t.text(p.source()) };
                },
            };
            if (p.tok.tag == .colon) {
                try p.advance();
                const pat = try p.parseBindingPattern(is_lexical_decl);
                max_depth = @max(max_depth, pat.depth);
                var default: ?*const ast.Expr = null;
                if (p.tok.tag == .eq) {
                    try p.advance();
                    default = try p.nestedAssignment();
                    max_depth = @max(max_depth, default.?.depth);
                    if (pat.data == .binding) inferExprName(default.?, pat.data.binding.name);
                }
                const end_pos = if (default) |d| d.span.end else pat.span.end;
                try props.append(p.arena, .{ .key = k, .pattern = pat, .default = default, .shorthand = false, .span = .{ .start = t.start, .end = end_pos } });
            } else {
                if (k != .name or t.tag != .identifier) return p.fail(.{ .syntax_error = "unexpected token in object pattern" }, p.tok);
                const name = k.name;
                if (token.reserved_identifiers.has(name)) return p.fail(.{ .syntax_error = "reserved word cannot be a binding name" }, t);
                if (std.mem.eql(u8, name, "let")) {
                    if (is_lexical_decl) return p.fail(.{ .syntax_error = "let is disallowed as a lexically bound name" }, t);
                    return p.fail(.{ .unsupported = .syntax }, t);
                }
                if (std.mem.eql(u8, name, "arguments")) return p.fail(.{ .unsupported = .arguments }, t);
                if (std.mem.eql(u8, name, "await")) {
                    return switch (p.async_ctx) {
                        .none => p.fail(.{ .unsupported = .syntax }, t),
                        .params, .body => p.fail(.{ .syntax_error = "'await' is not a valid identifier name in an async function" }, t),
                    };
                }
                if (std.mem.eql(u8, name, "yield") and p.yield_ctx != .none) {
                    return p.fail(.{ .syntax_error = "'yield' is not a valid identifier name in a generator" }, t);
                }
                const d: ast.Declarator = .{ .name = name, .span = span(t, t), .binding = p.binding_count, .init = null };
                p.binding_count += 1;
                const pat = try p.patNode(d.span, .{ .binding = d }, 0);
                var default: ?*const ast.Expr = null;
                if (p.tok.tag == .eq) {
                    try p.advance();
                    default = try p.nestedAssignment();
                    max_depth = @max(max_depth, default.?.depth);
                    inferExprName(default.?, name);
                }
                const end_pos = if (default) |def| def.span.end else t.end;
                try props.append(p.arena, .{ .key = k, .pattern = pat, .default = default, .shorthand = true, .span = .{ .start = t.start, .end = end_pos } });
            }
            if (p.tok.tag != .comma) break;
            try p.advance();
        }
        const close = p.tok;
        if (close.tag != .r_brace) return p.fail(.{ .syntax_error = "expected '}'" }, close);
        try p.advance();
        return p.patNode(span(open, close), .{ .object = .{ .props = props.items, .rest = rest } }, max_depth);
    }

    fn endStatement(p: *Parser) Error!void {
        const t = p.tok;
        if (t.tag == .semicolon) return p.advance();
        if (t.newline_before or t.tag == .eof or t.tag == .r_brace) return p.fail(.{ .unsupported = .asi }, t);
        return p.unexpectedAfterExpression(t);
    }

    fn expectAfterExpression(p: *Parser, tag: Tag) Error!void {
        if (p.tok.tag != tag) return p.unexpectedAfterExpression(p.tok);
        try p.advance();
    }

    fn boxed(p: *Parser, s: ast.Stmt) Error!*const ast.Stmt {
        const ptr = try p.arena.create(ast.Stmt);
        ptr.* = s;
        return ptr;
    }

    // ------------------------------------------------------------ expressions

    /// Expression := Assignment (',' Assignment)*. Comma is left-associative and binds loosest.
    fn expression(p: *Parser) Error!*const ast.Expr {
        var lhs = try p.assignment();
        while (p.tok.tag == .comma) {
            try p.advance();
            const rhs = try p.assignment();
            p.last_was_paren = false;
            lhs = try p.node(
                .{ .start = lhs.span.start, .end = rhs.span.end },
                .{ .binary = .{ .op = .comma, .lhs = lhs, .rhs = rhs } },
                @max(lhs.depth, rhs.depth),
            );
        }
        return lhs;
    }

    fn assignment(p: *Parser) Error!*const ast.Expr {
        const e = try p.expressionRaw();
        try p.rejectCoverExpr(e);
        return e;
    }

    /// Parses an expression without rejecting CoverInitializedName / array holes at the
    /// top level, so `[a, , b] = ...`, `{ a = 1 } = ...`, and `({ a = 1 }) => ...` can
    /// reinterpret them as patterns.
    fn expressionRaw(p: *Parser) Error!*const ast.Expr {
        try p.enter();
        defer p.depth -= 1;
        p.last_was_paren = false;
        if (p.tok.tag == .identifier) {
            if (p.isText(p.tok, "yield") and p.yield_ctx != .none) {
                if (p.yield_ctx == .params) {
                    return p.fail(.{ .syntax_error = "yield is not valid in generator parameters" }, p.tok);
                }
                const yield_tok = p.tok;
                p.yield_count += 1;
                try p.advance(); // `yield`
                if (!p.tok.newline_before and p.tok.tag == .star) {
                    try p.advance(); // `*`
                    const operand = try p.assignment();
                    return p.node(.{ .start = yield_tok.start, .end = operand.span.end }, .{ .yield = .{ .star = true, .value = operand } }, operand.depth);
                }
                const no_operand = p.tok.newline_before or switch (p.tok.tag) {
                    .r_paren, .r_bracket, .r_brace, .comma, .semicolon, .colon, .eof => true,
                    else => false,
                };
                if (no_operand) {
                    return p.node(.{ .start = yield_tok.start, .end = yield_tok.end }, .{ .yield = .{ .star = false, .value = null } }, 0);
                }
                const operand = try p.assignment();
                return p.node(.{ .start = yield_tok.start, .end = operand.span.end }, .{ .yield = .{ .star = false, .value = operand } }, operand.depth);
            }
            if (p.isText(p.tok, "async")) {
                var copy = p.lexer;
                const t1 = try copy.next();
                if (t1.tag == .arrow) return p.arrowSingle(false, p.tok.start);
                if (!t1.newline_before and t1.tag == .identifier and !p.isText(t1, "function")) {
                    const t2 = try copy.next();
                    if (t2.tag == .arrow and !t2.newline_before) {
                        const async_start = p.tok.start;
                        try p.advance(); // `async`
                        return p.arrowSingle(true, async_start);
                    }
                }
                if (!t1.newline_before and t1.tag == .l_paren) {
                    const async_tok = p.tok;
                    try p.advance(); // `async`
                    const await_before = p.await_count;
                    const yield_before = p.yield_count;
                    const saved_in_async_paren = p.in_async_paren;
                    const saved_await_span = p.async_paren_await_span;
                    p.in_async_paren = (p.async_ctx == .none);
                    p.async_paren_await_span = null;
                    defer {
                        p.in_async_paren = saved_in_async_paren;
                        p.async_paren_await_span = saved_await_span;
                    }
                    const res = try p.parseParenList();
                    const paren_await = p.async_paren_await_span;
                    p.in_async_paren = saved_in_async_paren;
                    p.async_paren_await_span = saved_await_span;
                    if (p.tok.tag == .arrow) {
                        if (p.tok.newline_before) return p.fail(.{ .syntax_error = "line terminator before '=>'" }, p.tok);
                        if (p.await_count != await_before or paren_await != null)
                            return p.failAt(.{ .syntax_error = "await is not valid in async arrow parameters" }, res.start, res.end);
                        if (p.yield_count != yield_before)
                            return p.failAt(.{ .syntax_error = "yield is not valid in arrow parameters" }, res.start, res.end);
                        return p.arrowFromParenList(res, true, async_tok.start);
                    }
                    if (paren_await) |sp| return p.failAt(.{ .unsupported = .syntax }, sp.start, sp.end);
                    const call_node = try p.finishAsyncCall(async_tok, res);
                    const full = try p.conditionalFromPrimary(call_node);
                    return p.finishAssignment(full, false);
                }
            } else {
                const next = try p.peek();
                if (next.tag == .arrow) return p.arrowSingle(false, p.tok.start);
            }
        }
        var lhs_was_paren = false;
        const lhs = if (p.tok.tag == .l_paren) blk: {
            const await_before = p.await_count;
            const yield_before = p.yield_count;
            const res = try p.parseParenList();
            if (p.tok.tag == .arrow) {
                if (p.tok.newline_before) return p.fail(.{ .syntax_error = "line terminator before '=>'" }, p.tok);
                if (p.await_count != await_before) return p.failAt(.{ .syntax_error = "await is not valid in arrow parameters" }, res.start, res.end);
                if (p.yield_count != yield_before) return p.failAt(.{ .syntax_error = "yield is not valid in arrow parameters" }, res.start, res.end);
                return p.arrowFromParenList(res, false, res.start);
            }
            const inner = try p.finishParenAsExpr(res);
            p.last_was_paren = true;
            const full = try p.conditionalFromPrimary(inner);
            lhs_was_paren = p.last_was_paren;
            break :blk full;
        } else try p.conditional();

        return p.finishAssignment(lhs, lhs_was_paren);
    }

    fn finishAssignment(p: *Parser, lhs: *const ast.Expr, lhs_was_paren: bool) Error!*const ast.Expr {
        const op = assignOp(p.tok.tag) orelse return lhs;
        if (op == .plain and (lhs.data == .array or lhs.data == .object)) {
            if (lhs_was_paren) return p.failAt(.{ .syntax_error = "invalid assignment target" }, lhs.span.start, lhs.span.end);
            const pat = try p.exprToAssignPattern(lhs);
            try p.advance();
            const value = try p.assignment();
            p.last_was_paren = false;
            return p.node(
                .{ .start = lhs.span.start, .end = value.span.end },
                .{ .assign_pattern = .{ .pattern = pat, .value = value } },
                @max(lhs.depth, value.depth),
            );
        }
        try p.rejectCoverExpr(lhs);
        // Parentheses are transparent for single identifiers, so `(x) = 1` arrives here as `.identifier`.
        const target = try p.assignTarget(lhs, "invalid assignment target");
        try p.advance();
        const value = try p.assignment();
        if (op == .plain and target == .ref) inferExprName(value, target.ref.name);
        p.last_was_paren = false;
        return p.node(
            .{ .start = lhs.span.start, .end = value.span.end },
            .{ .assign = .{ .op = op, .target = target, .value = value } },
            @max(lhs.depth, value.depth),
        );
    }

    fn finishAsyncCall(p: *Parser, async_tok: Token, res: ParenList) Error!*const ast.Expr {
        const id = p.ref_count;
        p.ref_count += 1;
        const async_span = span(async_tok, async_tok);
        const callee = try p.node(async_span, .{ .identifier = .{ .name = async_tok.text(p.source()), .span = async_span, .id = id } }, 0);
        var args: std.ArrayList(*const ast.Expr) = .empty;
        var depth: u16 = 0;
        for (res.items) |it| {
            try p.rejectCoverExpr(it.expr);
            if (it.is_rest) {
                const sp = try p.node(it.span, .{ .spread = it.expr }, it.expr.depth);
                try args.append(p.arena, sp);
                depth = @max(depth, sp.depth);
            } else {
                try args.append(p.arena, it.expr);
                depth = @max(depth, it.expr.depth);
            }
        }
        p.last_was_paren = false;
        return p.node(.{ .start = async_tok.start, .end = res.end }, .{ .call = .{ .callee = callee, .args = args.items } }, depth);
    }

    const ParenItem = struct {
        expr: *const ast.Expr,
        is_rest: bool,
        was_paren: bool,
        span: ast.Span,
    };

    const ParenList = struct {
        start: u32,
        end: u32,
        items: []const ParenItem,
        has_trailing_comma: bool,
        has_rest_trailing_comma: bool,
        has_non_last_rest: bool,
    };

    fn parseParenList(p: *Parser) Error!ParenList {
        try p.enter();
        defer p.depth -= 1;
        const open = p.tok;
        try p.advance(); // `(`
        var items: std.ArrayList(ParenItem) = .empty;
        var has_trailing_comma = false;
        var has_rest_trailing_comma = false;
        var has_non_last_rest = false;
        while (p.tok.tag != .r_paren) {
            if (p.tok.tag == .eof) return p.fail(.{ .syntax_error = "unterminated parenthesised expression" }, open);
            const item_start = p.tok.start;
            if (p.tok.tag == .ellipsis) {
                try p.advance();
                const saved_no_in = p.no_in;
                p.no_in = false;
                defer p.no_in = saved_no_in;
                const e = try p.expressionRaw();
                try items.append(p.arena, .{ .expr = e, .is_rest = true, .was_paren = p.last_was_paren, .span = .{ .start = item_start, .end = e.span.end } });
                if (p.tok.tag == .comma) {
                    const next = try p.peek();
                    if (next.tag == .r_paren) {
                        has_rest_trailing_comma = true;
                        has_trailing_comma = true;
                        try p.advance();
                        break;
                    }
                    has_non_last_rest = true;
                    try p.advance();
                    continue;
                }
                break;
            }
            const saved_no_in = p.no_in;
            p.no_in = false;
            defer p.no_in = saved_no_in;
            const e = try p.expressionRaw();
            try items.append(p.arena, .{ .expr = e, .is_rest = false, .was_paren = p.last_was_paren, .span = .{ .start = item_start, .end = e.span.end } });
            if (p.tok.tag != .comma) break;
            try p.advance();
            if (p.tok.tag == .r_paren) {
                has_trailing_comma = true;
                break;
            }
        }
        const close = p.tok;
        try p.expectAfterExpression(.r_paren);
        return .{
            .start = open.start,
            .end = close.end,
            .items = items.items,
            .has_trailing_comma = has_trailing_comma,
            .has_rest_trailing_comma = has_rest_trailing_comma,
            .has_non_last_rest = has_non_last_rest,
        };
    }

    fn finishParenAsExpr(p: *Parser, res: ParenList) Error!*const ast.Expr {
        if (res.items.len == 0) return p.failAt(.{ .syntax_error = "unexpected token ')'" }, res.start, res.start + 1);
        for (res.items) |it| {
            if (it.is_rest) return p.failAt(.{ .syntax_error = "unexpected token '...'" }, it.span.start, it.span.end);
        }
        if (res.has_trailing_comma) return p.failAt(.{ .syntax_error = "unexpected token ')'" }, res.items[res.items.len - 1].span.end, res.items[res.items.len - 1].span.end + 1);
        if (res.items.len > 1) {
            var acc = res.items[0].expr;
            try p.rejectCoverExpr(acc);
            for (res.items[1..]) |it| {
                try p.rejectCoverExpr(it.expr);
                acc = try p.node(
                    .{ .start = acc.span.start, .end = it.expr.span.end },
                    .{ .binary = .{ .op = .comma, .lhs = acc, .rhs = it.expr } },
                    @max(acc.depth, it.expr.depth),
                );
            }
            return acc;
        }
        return res.items[0].expr;
    }

    fn arrowSingle(p: *Parser, is_async: bool, start: u32) Error!*const ast.Expr {
        try p.enter();
        defer p.depth -= 1;
        const id = p.function_count;
        p.function_count += 1;

        const outer_async_ctx = p.async_ctx;
        p.async_ctx = if (is_async) .params else .none;
        defer p.async_ctx = outer_async_ctx;

        const single = try p.bindingName(false);
        const pat = try p.patNode(single.span, .{ .binding = single }, 0);
        const buf = try p.arena.alloc(ast.Param, 1);
        buf[0] = .{ .pattern = pat, .default = null, .is_rest = false, .span = single.span };
        return p.arrowBody(start, id, buf, is_async);
    }

    fn arrowFromParenList(p: *Parser, res: ParenList, is_async: bool, start: u32) Error!*const ast.Expr {
        try p.enter();
        defer p.depth -= 1;
        const id = p.function_count;
        p.function_count += 1;

        const outer_async_ctx = p.async_ctx;
        p.async_ctx = if (is_async) .params else .none;
        defer p.async_ctx = outer_async_ctx;

        if (res.has_non_last_rest or res.has_rest_trailing_comma)
            return p.fail(.{ .syntax_error = "rest parameter must be last formal parameter" }, p.tok);
        var params: std.ArrayList(ast.Param) = .empty;
        for (res.items) |it| {
            if (it.was_paren) return p.failAt(.{ .syntax_error = "invalid arrow function parameter" }, it.span.start, it.span.end);
            if (it.is_rest) {
                if (it.expr.data == .assign or it.expr.data == .assign_pattern)
                    return p.failAt(.{ .syntax_error = "rest parameter may not have a default initializer" }, it.span.start, it.span.end);
                const pat = try p.exprToBindingPattern(it.expr);
                try params.append(p.arena, .{ .pattern = pat, .default = null, .is_rest = true, .span = it.span });
            } else {
                const param = try p.exprToArrowParam(it.expr, it.span);
                try params.append(p.arena, param);
            }
        }
        return p.arrowBody(start, id, params.items, is_async);
    }

    fn arrowBody(p: *Parser, start: u32, id: u32, params: []const ast.Param, is_async: bool) Error!*const ast.Expr {
        if (p.tok.tag != .arrow) return p.fail(.{ .syntax_error = "expected '=>'" }, p.tok);
        if (p.tok.newline_before) return p.fail(.{ .syntax_error = "line terminator before '=>'" }, p.tok);
        try p.advance(); // `=>`

        const outer_loops = p.loop_depth;
        const outer_switches = p.switch_depth;
        const outer_labels = p.labels;
        const outer_async_ctx = p.async_ctx;
        const outer_yield_ctx = p.yield_ctx;
        const outer_derived = p.in_derived_ctor;
        p.loop_depth = 0;
        p.switch_depth = 0;
        p.labels = .empty;
        if (p.in_derived_ctor == .direct) p.in_derived_ctor = .arrow;
        p.function_depth += 1;
        p.async_ctx = if (is_async) .body else .none;
        p.yield_ctx = .none;
        defer {
            p.loop_depth = outer_loops;
            p.switch_depth = outer_switches;
            p.labels = outer_labels;
            p.in_derived_ctor = outer_derived;
            p.function_depth -= 1;
            p.async_ctx = outer_async_ctx;
            p.yield_ctx = outer_yield_ctx;
        }

        var body: []const ast.Stmt = undefined;
        var end: u32 = undefined;
        if (p.tok.tag == .l_brace) {
            const parsed_body = try p.parseFunctionBody();
            body = parsed_body.body;
            end = parsed_body.end;
        } else {
            const expr = try p.assignment();
            const stmts = try p.arena.alloc(ast.Stmt, 1);
            stmts[0] = .{ .span = expr.span, .data = .{ .@"return" = expr } };
            body = stmts;
            end = expr.span.end;
        }

        const f = try p.arena.create(ast.Function);
        f.* = .{
            .span = .{ .start = start, .end = end },
            .id = id,
            .kind = .expression,
            .is_arrow = true,
            .is_async = is_async,
            .length = paramLength(params),
            .name = null,
            .params = params,
            .body = body,
        };
        return p.node(f.span, .{ .function = f }, 0);
    }

    /// ConditionalExpression := LogicalORExpression (`?` AssignmentExpression `:` AssignmentExpression)?
    fn conditional(p: *Parser) Error!*const ast.Expr {
        return p.conditionalFrom(try p.binary(0));
    }

    fn conditionalFromPrimary(p: *Parser, prim: *const ast.Expr) Error!*const ast.Expr {
        const post = try p.postfix(try p.calls(prim));
        if (post != prim) p.last_was_paren = false;
        const bin = try p.binaryFrom(post, 0);
        if (bin != post) p.last_was_paren = false;
        return p.conditionalFrom(bin);
    }

    fn conditionalFrom(p: *Parser, cond: *const ast.Expr) Error!*const ast.Expr {
        if (p.tok.tag != .question) return cond;
        try p.rejectCoverExpr(cond);
        p.last_was_paren = false;
        try p.enter();
        defer p.depth -= 1;
        try p.advance();
        // `then` allows `in` even inside `for (...; ...)` (`no_in = false`); `else` keeps the outer `no_in`.
        const then_expr = try p.nested();
        if (p.tok.tag != .colon) return p.fail(.{ .syntax_error = "expected ':'" }, p.tok);
        try p.advance();
        const else_expr = try p.assignment();
        return p.node(
            .{ .start = cond.span.start, .end = else_expr.span.end },
            .{ .conditional = .{ .cond = cond, .then_expr = then_expr, .else_expr = else_expr } },
            @max(cond.depth, @max(then_expr.depth, else_expr.depth)),
        );
    }

    /// Variables and members can be assigned to; anything else can't.
    fn assignTarget(p: *Parser, e: *const ast.Expr, msg: []const u8) Error!ast.Target {
        return switch (e.data) {
            .identifier => |r| .{ .ref = r },
            .member => |m| .{ .member = m },
            .super_member => |k| .{ .super_member = k },
            else => p.invalidTarget(e, msg),
        };
    }

    /// A nested expression in brackets, parentheses or a literal: `in` is an operator again.
    fn nested(p: *Parser) Error!*const ast.Expr {
        const saved = p.no_in;
        p.no_in = false;
        defer p.no_in = saved;
        return p.expression();
    }

    fn nestedAssignment(p: *Parser) Error!*const ast.Expr {
        const saved = p.no_in;
        p.no_in = false;
        defer p.no_in = saved;
        return p.assignment();
    }

    fn nestedRaw(p: *Parser) Error!*const ast.Expr {
        const saved = p.no_in;
        p.no_in = false;
        defer p.no_in = saved;
        return p.expressionRaw();
    }

    fn binary(p: *Parser, min_bp: u8) Error!*const ast.Expr {
        if (min_bp <= 7 and !p.no_in and p.tok.tag == .private_ident) {
            const next = try p.peek();
            if (p.isText(next, "in")) {
                const priv_tok = p.tok;
                try p.advance(); // #name
                try p.advance(); // in
                const rhs = try p.binary(8);
                try p.rejectCoverExpr(rhs);
                const lhs = try p.node(
                    .{ .start = priv_tok.start, .end = rhs.span.end },
                    .{ .private_in = .{ .name = priv_tok.text(p.source()), .rhs = rhs, .span = .{ .start = priv_tok.start, .end = priv_tok.end } } },
                    rhs.depth,
                );
                return p.binaryFrom(lhs, min_bp);
            }
        }
        return p.binaryFrom(try p.prefix(), min_bp);
    }

    fn binaryFrom(p: *Parser, lhs_in: *const ast.Expr, min_bp: u8) Error!*const ast.Expr {
        try p.enter();
        defer p.depth -= 1;

        var lhs = lhs_in;
        var saw_logical = false;
        var saw_nullish = false;
        while (true) {
            if (p.tok.tag == .eq2 or p.tok.tag == .neq2) return p.fail(.{ .unsupported = .loose_equality }, p.tok);
            const info: Infix = if (!p.no_in and p.isText(p.tok, "in"))
                .{ .op = .in, .bp = 7 }
            else if (p.isText(p.tok, "instanceof"))
                .{ .op = .instanceof, .bp = 7 }
            else
                infix(p.tok.tag) orelse break;
            if (info.bp < min_bp) break;
            try p.rejectCoverExpr(lhs);
            // JS forbids mixing `??` with `&&` or `||` without parentheses; the RHS of `??`
            // is a BitwiseORExpression (bp 3), so `a ?? b && c` falls through to `saw_nullish`.
            const rhs_min_bp: u8 = switch (info.op) {
                .nullish => blk: {
                    if (saw_logical) return p.fail(.{ .syntax_error = "cannot mix '??' with '&&' or '||'" }, p.tok);
                    saw_nullish = true;
                    break :blk 3;
                },
                .logical_and, .logical_or => blk: {
                    if (saw_nullish) return p.fail(.{ .syntax_error = "cannot mix '??' with '&&' or '||'" }, p.tok);
                    saw_logical = true;
                    break :blk info.bp + 1;
                },
                else => if (info.right_assoc) info.bp else info.bp + 1,
            };
            try p.advance();
            const rhs = try p.binary(rhs_min_bp);
            try p.rejectCoverExpr(rhs);
            lhs = try p.node(
                .{ .start = lhs.span.start, .end = rhs.span.end },
                .{ .binary = .{ .op = info.op, .lhs = lhs, .rhs = rhs } },
                @max(lhs.depth, rhs.depth),
            );
        }
        return lhs;
    }

    fn prefix(p: *Parser) Error!*const ast.Expr {
        const t = p.tok;
        switch (t.tag) {
            .minus, .plus, .bang, .tilde => {
                try p.advance();
                const operand = try p.binary(unary_bp);
                try p.rejectCoverExpr(operand);
                // JS forbids `-a ** b`: it is ambiguous whether `-` applies before or after `**`.
                // (`++a ** b` is fine: update expressions are not unary operators here.)
                if (p.tok.tag == .star_star)
                    return p.fail(.{ .syntax_error = "unary operator before '**' needs parentheses" }, t);
                const op: ast.UnaryOp = switch (t.tag) {
                    .minus => .neg,
                    .plus => .plus,
                    .bang => .not,
                    else => .bit_not,
                };
                return p.node(.{ .start = t.start, .end = operand.span.end }, .{ .unary = .{ .op = op, .operand = operand } }, operand.depth);
            },
            .plus2, .minus2 => {
                try p.advance();
                const operand = try p.binary(unary_bp);
                const target = try p.updateTarget(operand);
                return p.node(
                    .{ .start = t.start, .end = operand.span.end },
                    .{ .update = .{ .op = if (t.tag == .plus2) .inc else .dec, .prefix = true, .target = target } },
                    operand.depth,
                );
            },
            .identifier => if (p.isText(t, "delete")) {
                try p.advance();
                const operand = try p.binary(unary_bp);
                if (p.tok.tag == .star_star)
                    return p.fail(.{ .syntax_error = "unary operator before '**' needs parentheses" }, t);
                // `delete x` (a variable) and `delete 1` mean something in sloppy JS, but
                // only member (and optional member) deletion is part of ZQJS.
                switch (operand.data) {
                    .member => |m| {
                        if (m.is_private) return p.fail(.{ .syntax_error = "Private fields can not be deleted" }, t);
                        return p.node(.{ .start = t.start, .end = operand.span.end }, .{ .delete = m }, operand.depth);
                    },
                    .super_member => return p.node(.{ .start = t.start, .end = operand.span.end }, .delete_super, operand.depth),
                    .optional_chain => |oc| {
                        const last_kind = oc.steps[oc.steps.len - 1].kind;
                        if (last_kind == .call) return p.fail(.{ .unsupported = .syntax }, t);
                        if (last_kind == .private_prop) return p.fail(.{ .syntax_error = "Private fields can not be deleted" }, t);
                        return p.node(.{ .start = t.start, .end = operand.span.end }, .{ .delete_optional = oc }, operand.depth);
                    },
                    else => return p.fail(.{ .unsupported = .syntax }, t),
                }
            } else if (p.isText(t, "typeof")) {
                try p.advance();
                const operand = try p.binary(unary_bp);
                if (p.tok.tag == .star_star)
                    return p.fail(.{ .syntax_error = "unary operator before '**' needs parentheses" }, t);
                return p.node(.{ .start = t.start, .end = operand.span.end }, .{ .unary = .{ .op = .typeof, .operand = operand } }, operand.depth);
            } else if (p.isText(t, "await")) {
                switch (p.async_ctx) {
                    .none => {
                        if (p.in_async_paren) {
                            if (p.async_paren_await_span == null) p.async_paren_await_span = span(t, t);
                            return p.postfix(try p.calls(try p.primary()));
                        }
                        return p.fail(.{ .unsupported = .syntax }, t);
                    },
                    .params => return p.fail(.{ .syntax_error = "await is not valid in async function parameters" }, t),
                    .body => {
                        try p.advance();
                        const operand = try p.binary(unary_bp);
                        try p.rejectCoverExpr(operand);
                        if (p.tok.tag == .star_star)
                            return p.fail(.{ .syntax_error = "unary operator before '**' needs parentheses" }, t);
                        p.await_count += 1;
                        if (p.function_depth == 0) p.has_top_level_await = true;
                        return p.node(.{ .start = t.start, .end = operand.span.end }, .{ .await = operand }, operand.depth);
                    },
                }
            } else return p.postfix(try p.calls(try p.primary())),
            else => return p.postfix(try p.calls(try p.primary())),
        }
    }

    /// `x++` / `x--`. No line break is allowed before the operator: `x\n++y` is
    /// `x; ++y;` by ASI, which `endStatement` then reports.
    fn postfix(p: *Parser, operand: *const ast.Expr) Error!*const ast.Expr {
        const t = p.tok;
        if ((t.tag != .plus2 and t.tag != .minus2) or t.newline_before) return operand;
        const target = try p.updateTarget(operand);
        try p.advance();
        return p.node(
            .{ .start = operand.span.start, .end = t.end },
            .{ .update = .{ .op = if (t.tag == .plus2) .inc else .dec, .prefix = false, .target = target } },
            operand.depth,
        );
    }

    fn updateTarget(p: *Parser, operand: *const ast.Expr) Error!ast.Target {
        return p.assignTarget(operand, "invalid update target");
    }

    /// `f() = 1` and `f()++` are *runtime* ReferenceErrors in node (a web-compatibility
    /// rule), not SyntaxErrors, so for calls we must not claim a SyntaxError.
    fn invalidTarget(p: *Parser, e: *const ast.Expr, msg: []const u8) Error {
        if (e.data == .call or e.data == .new_call) return p.failAt(.{ .unsupported = .syntax }, e.span.start, e.span.end);
        return p.failAt(.{ .syntax_error = msg }, e.span.start, e.span.end);
    }

    fn expectPropertyName(p: *Parser) Error!Token {
        const name = p.tok;
        // Any identifier or keyword names a property: `o.if`, `o.this`. A literal,
        // `=` or a closing token can't follow `.` or `?.` in any JS; others (`o.#x`) might.
        if (name.tag != .identifier and !token.isKeyword(name.tag)) return switch (name.tag) {
            .eof, .semicolon, .comma, .eq, .r_paren, .r_bracket, .r_brace, .number, .string, .template_no_sub, .template_head, .dot, .question_dot => p.fail(.{ .syntax_error = "expected a property name after '.'" }, name),
            else => p.fail(.{ .unsupported = .syntax }, name),
        };
        try p.advance();
        return name;
    }

    fn memberStep(p: *Parser, callee: *const ast.Expr) Error!?*const ast.Expr {
        return switch (p.tok.tag) {
            .dot => blk: {
                try p.rejectCoverExpr(callee);
                try p.advance();
                if (p.tok.tag == .private_ident) {
                    const name = p.tok;
                    try p.advance();
                    break :blk try p.node(.{ .start = callee.span.start, .end = name.end }, .{ .member = .{ .object = callee, .key = .{ .name = name.text(p.source()) }, .is_private = true } }, callee.depth);
                }
                const name = try p.expectPropertyName();
                break :blk try p.node(.{ .start = callee.span.start, .end = name.end }, .{ .member = .{ .object = callee, .key = .{ .name = name.text(p.source()) } } }, callee.depth);
            },
            .l_bracket => blk: {
                try p.rejectCoverExpr(callee);
                try p.advance();
                const k = try p.nested();
                const close = p.tok;
                try p.expectAfterExpression(.r_bracket);
                break :blk try p.node(.{ .start = callee.span.start, .end = close.end }, .{ .member = .{ .object = callee, .key = .{ .computed = k } } }, @max(callee.depth, k.depth));
            },
            .template_no_sub, .template_head => blk: {
                try p.rejectCoverExpr(callee);
                break :blk try p.taggedTemplate(callee);
            },
            else => null,
        };
    }

    fn members(p: *Parser, callee_in: *const ast.Expr) Error!*const ast.Expr {
        var callee = callee_in;
        while (try p.memberStep(callee)) |next| callee = next;
        return callee;
    }

    /// `callee(args)`, `object.name`, `object[key]`, `callee\`...\``, or an optional chain starting at `?.`.
    /// Unlike `++`, these may continue on the next line: `x\n(2)` calls x, `x\n[0]` indexes it.
    fn calls(p: *Parser, callee_in: *const ast.Expr) Error!*const ast.Expr {
        var callee = callee_in;
        while (true) {
            if (p.tok.tag == .l_paren) {
                try p.rejectCoverExpr(callee);
                callee = try p.callArgs(callee);
            } else if (p.tok.tag == .question_dot) {
                try p.rejectCoverExpr(callee);
                return p.optionalChain(callee);
            } else if (try p.memberStep(callee)) |next| {
                callee = next;
            } else return callee;
        }
    }

    fn optionalChain(p: *Parser, base: *const ast.Expr) Error!*const ast.Expr {
        var steps: std.ArrayList(ast.OptionalChain.Step) = .empty;
        var depth = base.depth;
        var end = base.span.end;
        while (true) {
            const optional = p.tok.tag == .question_dot;
            if (optional) {
                try p.advance();
                if (p.tok.tag == .l_paren) {
                    const parsed = try p.parseCallArgs(depth);
                    try steps.append(p.arena, .{ .optional = true, .kind = .{ .call = parsed.args } });
                    depth = parsed.depth;
                    end = parsed.end;
                } else if (p.tok.tag == .l_bracket) {
                    try p.advance();
                    const k = try p.nested();
                    const close = p.tok;
                    try p.expectAfterExpression(.r_bracket);
                    try steps.append(p.arena, .{ .optional = true, .kind = .{ .elem = k } });
                    depth = @max(depth, k.depth);
                    end = close.end;
                } else if (p.tok.tag == .private_ident) {
                    const name = p.tok;
                    try p.advance();
                    try steps.append(p.arena, .{ .optional = true, .kind = .{ .private_prop = name.text(p.source()) } });
                    end = name.end;
                } else {
                    const name = try p.expectPropertyName();
                    try steps.append(p.arena, .{ .optional = true, .kind = .{ .prop = name.text(p.source()) } });
                    end = name.end;
                }
            } else if (p.tok.tag == .l_paren) {
                const parsed = try p.parseCallArgs(depth);
                try steps.append(p.arena, .{ .optional = false, .kind = .{ .call = parsed.args } });
                depth = parsed.depth;
                end = parsed.end;
            } else if (p.tok.tag == .l_bracket) {
                try p.advance();
                const k = try p.nested();
                const close = p.tok;
                try p.expectAfterExpression(.r_bracket);
                try steps.append(p.arena, .{ .optional = false, .kind = .{ .elem = k } });
                depth = @max(depth, k.depth);
                end = close.end;
            } else if (p.tok.tag == .dot) {
                try p.advance();
                if (p.tok.tag == .private_ident) {
                    const name = p.tok;
                    try p.advance();
                    try steps.append(p.arena, .{ .optional = false, .kind = .{ .private_prop = name.text(p.source()) } });
                    end = name.end;
                } else {
                    const name = try p.expectPropertyName();
                    try steps.append(p.arena, .{ .optional = false, .kind = .{ .prop = name.text(p.source()) } });
                    end = name.end;
                }
            } else break;
        }
        if (p.tok.tag == .template_no_sub or p.tok.tag == .template_head) {
            return p.fail(.{ .syntax_error = "tagged template literal is not allowed in optional chain" }, p.tok);
        }
        return p.node(.{ .start = base.span.start, .end = end }, .{ .optional_chain = .{ .base = base, .steps = steps.items } }, depth);
    }

    fn newExpr(p: *Parser) Error!*const ast.Expr {
        const start = p.tok.start;
        try p.advance();
        if (p.depth >= p.limits.max_nesting_depth) return p.limitExceeded(p.tok.start, p.tok.end);
        p.depth += 1;
        defer p.depth -= 1;
        const target = if (p.tok.tag == .identifier and std.mem.eql(u8, p.tok.text(p.source()), "new"))
            try p.newExpr()
        else
            try p.members(try p.primary());
        if (p.tok.tag == .l_paren) {
            const call_node = try p.callArgs(target);
            const c = call_node.data.call;
            return p.node(.{ .start = start, .end = call_node.span.end }, .{ .new_call = .{ .callee = c.callee, .args = c.args } }, call_node.depth);
        }
        if (p.tok.tag == .question_dot) {
            return p.fail(.{ .syntax_error = "optional chaining is not allowed in 'new'" }, p.tok);
        }
        return p.node(.{ .start = start, .end = target.span.end }, .{ .new_call = .{ .callee = target, .args = &.{} } }, target.depth);
    }

    const ParsedArgs = struct { args: []const *const ast.Expr, depth: u16, end: u32 };

    fn parseCallArgs(p: *Parser, base_depth: u16) Error!ParsedArgs {
        try p.advance();
        var args: std.ArrayList(*const ast.Expr) = .empty;
        var depth = base_depth;
        while (p.tok.tag != .r_paren) {
            if (p.tok.tag == .ellipsis) {
                const ell = p.tok;
                try p.advance();
                const inner = try p.nestedAssignment();
                const sp = try p.node(.{ .start = ell.start, .end = inner.span.end }, .{ .spread = inner }, inner.depth);
                try args.append(p.arena, sp);
                depth = @max(depth, sp.depth);
            } else {
                const arg = try p.nestedAssignment();
                try args.append(p.arena, arg);
                depth = @max(depth, arg.depth);
            }
            if (p.tok.tag != .comma) break;
            try p.advance(); // a trailing comma is allowed: `f(1,)`
        }
        const close = p.tok;
        try p.expectAfterExpression(.r_paren);
        return .{ .args = args.items, .depth = depth, .end = close.end };
    }

    fn callArgs(p: *Parser, callee: *const ast.Expr) Error!*const ast.Expr {
        const parsed = try p.parseCallArgs(callee.depth);
        return p.node(
            .{ .start = callee.span.start, .end = parsed.end },
            .{ .call = .{ .callee = callee, .args = parsed.args } },
            parsed.depth,
        );
    }

    /// `[a, ...b, …]`. Holes (`[1,,2]`) are allowed during parsing as a cover grammar
    /// for array patterns (`[a,,b] = x`), and rejected as `Unsupported(sparse_array)` if
    /// not reinterpreted as a pattern.
    fn arrayLiteral(p: *Parser) Error!*const ast.Expr {
        const open = p.tok;
        try p.advance();
        var items: std.ArrayList(*const ast.Expr) = .empty;
        var depth: u16 = 0;
        var has_cover_init = false;
        var has_hole = false;
        var has_rest_trailing_comma = false;
        while (p.tok.tag != .r_bracket) {
            if (p.tok.tag == .comma) {
                const c_tok = p.tok;
                if (!has_hole) p.hole_span = span(c_tok, c_tok);
                has_hole = true;
                try items.append(p.arena, try p.node(span(c_tok, c_tok), .hole, 0));
                try p.advance();
                continue;
            }
            if (p.tok.tag == .eof) return p.fail(.{ .syntax_error = "unterminated array literal" }, open);
            if (p.tok.tag == .ellipsis) {
                const ell = p.tok;
                try p.advance();
                const inner = try p.nestedRaw();
                if (inner.has_cover_init) has_cover_init = true;
                if (inner.has_hole) has_hole = true;
                const sp = try p.node(.{ .start = ell.start, .end = inner.span.end }, .{ .spread = inner }, inner.depth);
                try items.append(p.arena, sp);
                depth = @max(depth, sp.depth);
                if (p.tok.tag != .comma) break;
                try p.advance();
                if (p.tok.tag == .r_bracket) {
                    has_rest_trailing_comma = true;
                    break;
                }
                continue;
            }
            const e = try p.nestedRaw();
            if (e.has_cover_init) has_cover_init = true;
            if (e.has_hole) has_hole = true;
            try items.append(p.arena, e);
            depth = @max(depth, e.depth);
            if (p.tok.tag != .comma) break;
            try p.advance(); // a trailing comma adds no element
        }
        const close = p.tok;
        try p.expectAfterExpression(.r_bracket);
        const arr = try p.node(span(open, close), .{ .array = items.items }, depth);
        if (has_cover_init or has_hole or has_rest_trailing_comma) {
            const mut = @constCast(arr);
            mut.has_cover_init = has_cover_init;
            mut.has_hole = has_hole;
            mut.has_rest_trailing_comma = has_rest_trailing_comma;
        }
        return arr;
    }

    /// `{ key: value, [expr]: value, name, method() {…}, ...rest, … }`.
    fn parsePropertyKey(p: *Parser) Error!ast.PropertyKey {
        const kt = p.tok;
        return switch (kt.tag) {
            .l_bracket => try p.computedPropertyKey(),
            .string => try p.stringPropertyKey(kt),
            .number => try p.numberPropertyKey(kt),
            else => {
                if (kt.tag != .identifier and !token.isKeyword(kt.tag)) {
                    return p.fail(.{ .syntax_error = "expected property name" }, kt);
                }
                try p.advance();
                return .{ .name = kt.text(p.source()) };
            },
        };
    }

    fn validateAccessorParams(p: *Parser, is_getter: bool, params: []const ast.Param, err_tok: token.Token) Error!void {
        if (is_getter) {
            if (params.len != 0) return p.fail(.{ .syntax_error = "Getter must not have any formal parameters" }, err_tok);
        } else {
            if (params.len != 1 or params[0].is_rest) {
                return p.fail(.{ .syntax_error = "Setter must have exactly one formal parameter" }, err_tok);
            }
        }
    }

    fn objectLiteral(p: *Parser) Error!*const ast.Expr {
        const open = p.tok;
        try p.advance();
        var props: std.ArrayList(ast.PropertyDef) = .empty;
        var depth: u16 = 0;
        var has_cover_init = false;
        var has_hole = false;
        var has_rest_trailing_comma = false;
        while (p.tok.tag != .r_brace) {
            const t = p.tok;
            if (t.tag == .eof) return p.fail(.{ .syntax_error = "unterminated object literal" }, open);
            if (t.tag == .ellipsis) {
                try p.advance();
                const inner = try p.nestedRaw();
                try p.rejectCoverExpr(inner);
                try props.append(p.arena, .{ .spread = .{ .expr = inner, .span = .{ .start = t.start, .end = inner.span.end } } });
                depth = @max(depth, inner.depth);
                if (p.tok.tag != .comma) break;
                try p.advance();
                if (p.tok.tag == .r_brace) {
                    has_rest_trailing_comma = true;
                    break;
                }
                continue;
            }
            var is_async_method = false;
            var is_generator_method = false;
            var prop_kind: @FieldType(@FieldType(ast.PropertyDef, "prop"), "kind") = .init;
            const k: ast.PropertyKey = switch (t.tag) {
                .l_bracket => try p.computedPropertyKey(),
                .string => try p.stringPropertyKey(t),
                .number => try p.numberPropertyKey(t),
                .star => blk: {
                    is_generator_method = true;
                    try p.advance(); // `*`
                    break :blk try p.parsePropertyKey();
                },
                else => blk: {
                    if (t.tag != .identifier and !token.isKeyword(t.tag)) return p.fail(.{ .unsupported = .syntax }, t);
                    const name = t.text(p.source());
                    if (std.mem.eql(u8, name, "get") or std.mem.eql(u8, name, "set")) {
                        const next = try p.peek();
                        switch (next.tag) {
                            .colon, .l_paren, .comma, .r_brace, .eq => {},
                            else => {
                                prop_kind = if (std.mem.eql(u8, name, "get")) .getter else .setter;
                                try p.advance(); // `get` / `set`
                                break :blk try p.parsePropertyKey();
                            },
                        }
                    } else if (std.mem.eql(u8, name, "async")) {
                        const next = try p.peek();
                        switch (next.tag) {
                            .colon, .l_paren, .comma, .r_brace, .eq => {},
                            else => {
                                if (next.newline_before) return p.fail(.{ .syntax_error = "unexpected token in object literal" }, next);
                                is_async_method = true;
                                try p.advance(); // `async`
                                if (p.tok.tag == .star) { // `async *m() {}` (D68)
                                    is_generator_method = true;
                                    try p.advance();
                                }
                                break :blk try p.parsePropertyKey();
                            },
                        }
                    }
                    try p.advance();
                    break :blk .{ .name = name };
                },
            };
            if ((is_async_method or is_generator_method or prop_kind != .init) and p.tok.tag != .l_paren) {
                return p.fail(.{ .syntax_error = "expected '(' after method name" }, p.tok);
            }
            switch (p.tok.tag) {
                .colon => {
                    if (isProtoKey(k)) return p.fail(.{ .unsupported = .builtin }, t); // sets the prototype
                    try p.advance();
                    const value = try p.nestedRaw();
                    if (value.has_cover_init) has_cover_init = true;
                    if (value.has_hole) has_hole = true;
                    if (try p.keyInferredName(k)) |inferred| inferExprName(value, inferred);
                    try props.append(p.arena, .{ .prop = .{ .key = k, .value = value, .shorthand = false, .span = .{ .start = t.start, .end = value.span.end } } });
                    depth = @max(depth, value.depth);
                },
                .l_paren => {
                    const f = try p.functionRest(t.start, .expression, null, is_async_method, is_generator_method);
                    if (prop_kind != .init) {
                        try p.validateAccessorParams(prop_kind == .getter, f.params, t);
                    }
                    const mut_f = @constCast(f);
                    mut_f.is_method = true;
                    if (try p.keyInferredName(k)) |inferred| mut_f.inferred_name = inferred;
                    const value = try p.node(f.span, .{ .function = f }, 0);
                    try props.append(p.arena, .{ .prop = .{ .key = k, .value = value, .shorthand = false, .kind = prop_kind, .span = .{ .start = t.start, .end = value.span.end } } });
                },
                .comma, .r_brace => {
                    // Shorthand `{ x }` is a reference to the variable x.
                    if (k != .name or t.tag != .identifier) return p.fail(.{ .syntax_error = "unexpected token in object literal" }, p.tok);
                    if (token.reserved_identifiers.has(k.name)) return p.fail(.{ .syntax_error = "reserved word as shorthand property" }, t);
                    if (std.mem.eql(u8, k.name, "let")) return p.fail(.{ .unsupported = .syntax }, t);
                    if (std.mem.eql(u8, k.name, "arguments")) return p.fail(.{ .unsupported = .arguments }, t);
                    if (std.mem.eql(u8, k.name, "await")) {
                        return switch (p.async_ctx) {
                            .none => p.fail(.{ .unsupported = .syntax }, t),
                            .params, .body => p.fail(.{ .syntax_error = "'await' is not a valid identifier name in an async function" }, t),
                        };
                    }
                    if (std.mem.eql(u8, k.name, "yield") and p.yield_ctx != .none) {
                        return p.fail(.{ .syntax_error = "'yield' is not a valid identifier name in a generator" }, t);
                    }
                    const id = p.ref_count;
                    p.ref_count += 1;
                    const value = try p.node(span(t, t), .{ .identifier = .{ .name = k.name, .span = span(t, t), .id = id } }, 0);
                    try props.append(p.arena, .{ .prop = .{ .key = k, .value = value, .shorthand = true, .span = span(t, t) } });
                },
                .eq => {
                    // CoverInitializedName `{ a = 1 }`: only valid inside a destructuring pattern.
                    if (k != .name or t.tag != .identifier) return p.fail(.{ .syntax_error = "unexpected '=' in object literal" }, p.tok);
                    if (token.reserved_identifiers.has(k.name)) return p.fail(.{ .syntax_error = "reserved word as shorthand property" }, t);
                    if (std.mem.eql(u8, k.name, "let")) return p.fail(.{ .unsupported = .syntax }, t);
                    if (std.mem.eql(u8, k.name, "arguments")) return p.fail(.{ .unsupported = .arguments }, t);
                    if (std.mem.eql(u8, k.name, "await")) {
                        return switch (p.async_ctx) {
                            .none => p.fail(.{ .unsupported = .syntax }, t),
                            .params, .body => p.fail(.{ .syntax_error = "'await' is not a valid identifier name in an async function" }, t),
                        };
                    }
                    if (std.mem.eql(u8, k.name, "yield") and p.yield_ctx != .none) {
                        return p.fail(.{ .syntax_error = "'yield' is not a valid identifier name in a generator" }, t);
                    }
                    const eq_tok = p.tok;
                    try p.advance();
                    const def = try p.nestedAssignment();
                    if (!has_cover_init) p.cover_init_span = span(eq_tok, eq_tok);
                    has_cover_init = true;
                    const id = p.ref_count;
                    p.ref_count += 1;
                    const ref: ast.Ref = .{ .name = k.name, .span = span(t, t), .id = id };
                    try props.append(p.arena, .{ .cover_init = .{ .ref = ref, .default = def, .span = .{ .start = t.start, .end = def.span.end } } });
                    depth = @max(depth, def.depth);
                },
                .number, .string, .identifier => return p.fail(.{ .syntax_error = "unexpected token in object literal" }, p.tok),
                else => return p.fail(.{ .unsupported = .syntax }, p.tok),
            }
            if (k == .computed) depth = @max(depth, k.computed.depth);
            if (p.tok.tag != .comma) break;
            try p.advance(); // a trailing comma is allowed
        }
        const close = p.tok;
        try p.expectAfterExpression(.r_brace);
        const obj = try p.node(span(open, close), .{ .object = props.items }, depth);
        if (has_cover_init or has_hole or has_rest_trailing_comma) {
            const mut = @constCast(obj);
            mut.has_cover_init = has_cover_init;
            mut.has_hole = has_hole;
            mut.has_rest_trailing_comma = has_rest_trailing_comma;
        }
        return obj;
    }

    fn computedPropertyKey(p: *Parser) Error!ast.PropertyKey {
        try p.advance();
        const e = try p.nested();
        try p.expectAfterExpression(.r_bracket);
        return .{ .computed = e };
    }

    fn stringPropertyKey(p: *Parser, t: Token) Error!ast.PropertyKey {
        const units = try p.decodeString(t);
        try p.advance();
        return .{ .string = units };
    }

    fn numberPropertyKey(p: *Parser, t: Token) Error!ast.PropertyKey {
        const n = try number.literalValue(p.arena, t.text(p.source()));
        try p.advance();
        return .{ .number = n };
    }

    /// The literal key `__proto__:` (not computed, not shorthand) sets the prototype.
    fn isProtoKey(k: ast.PropertyKey) bool {
        return switch (k) {
            .name => |n| std.mem.eql(u8, n, "__proto__"),
            .string => |u| std.mem.eql(u16, u, std.unicode.utf8ToUtf16LeStringLiteral("__proto__")),
            else => false,
        };
    }

    fn keyInferredName(p: *Parser, k: ast.PropertyKey) Error!?[]const u8 {
        return switch (k) {
            .name => |n| n,
            .string => |units| blk: {
                for (units) |u| if (u >= 0x80) break :blk null;
                const buf = try p.arena.alloc(u8, units.len);
                for (units, buf) |u, *b| b.* = @intCast(u);
                break :blk buf;
            },
            else => null,
        };
    }

    fn primary(p: *Parser) Error!*const ast.Expr {
        const t = p.tok;
        const s = span(t, t);
        switch (t.tag) {
            .number => {
                const value = try number.literalValue(p.arena, t.text(p.source()));
                try p.advance();
                return p.node(s, .{ .number = value }, 0);
            },
            .string => {
                const units = try p.decodeString(t);
                try p.advance();
                return p.node(s, .{ .string = units }, 0);
            },
            .template_no_sub, .template_head => return p.templateLiteral(),
            .kw_true, .kw_false => {
                try p.advance();
                return p.node(s, .{ .boolean = t.tag == .kw_true }, 0);
            },
            .kw_null => {
                try p.advance();
                return p.node(s, .null, 0);
            },
            .l_bracket => return p.arrayLiteral(),
            .l_brace => return p.objectLiteral(),
            .identifier => {
                const name = t.text(p.source());
                if (std.mem.eql(u8, name, "this")) {
                    // At script level `this` is the global object, which ZQJS doesn't have.
                    if (p.function_depth == 0) return p.fail(.{ .unsupported = .sloppy_this }, t);
                    try p.advance();
                    return p.node(s, .this, 0);
                }
                if (std.mem.eql(u8, name, "function")) {
                    const f = try p.function(.expression, false, t.start);
                    return p.node(f.span, .{ .function = f }, 0);
                }
                if (std.mem.eql(u8, name, "class")) {
                    const c = try p.parseClass(.expression);
                    return p.node(c.span, .{ .class = c }, 0);
                }
                if (std.mem.eql(u8, name, "super")) {
                    try p.advance();
                    if (p.tok.tag == .l_paren) {
                        switch (p.in_derived_ctor) {
                            .none => return p.fail(.{ .syntax_error = "'super' keyword unexpected here" }, t),
                            .arrow => return p.fail(.{ .unsupported = .syntax }, t),
                            .direct => {},
                        }
                        const parsed = try p.parseCallArgs(0);
                        return p.node(.{ .start = t.start, .end = parsed.end }, .{ .super_call = parsed.args }, parsed.depth);
                    }
                    if (!p.in_class_method) return p.fail(.{ .syntax_error = "'super' keyword unexpected here" }, t);
                    if (p.tok.tag == .dot) {
                        try p.advance();
                        if (p.tok.tag == .private_ident) return p.fail(.{ .syntax_error = "Private fields cannot be accessed on super" }, p.tok);
                        const prop = try p.expectPropertyName();
                        return p.node(.{ .start = t.start, .end = prop.end }, .{ .super_member = .{ .name = prop.text(p.source()) } }, 0);
                    }
                    if (p.tok.tag == .l_bracket) {
                        try p.advance();
                        const k = try p.nested();
                        const close = p.tok;
                        try p.expectAfterExpression(.r_bracket);
                        return p.node(.{ .start = t.start, .end = close.end }, .{ .super_member = .{ .computed = k } }, k.depth);
                    }
                    return p.fail(.{ .syntax_error = "'super' keyword unexpected here" }, t);
                }
                if (std.mem.eql(u8, name, "async")) {
                    const next = try p.peek();
                    if (!next.newline_before and p.isText(next, "function")) {
                        try p.advance(); // `async`
                        const f = try p.function(.expression, true, t.start);
                        return p.node(f.span, .{ .function = f }, 0);
                    }
                }
                if (std.mem.eql(u8, name, "new")) {
                    return p.newExpr();
                }
                // Inside a function, `arguments` is the arguments object.
                if (std.mem.eql(u8, name, "arguments")) return p.fail(.{ .unsupported = .arguments }, t);
                if (std.mem.eql(u8, name, "await")) {
                    switch (p.async_ctx) {
                        .none => if (!p.in_async_paren) return p.fail(.{ .unsupported = .syntax }, t),
                        .params, .body => return p.fail(.{ .syntax_error = "'await' is not a valid identifier name in an async function" }, t),
                    }
                }
                if (std.mem.eql(u8, name, "yield") and p.yield_ctx != .none) {
                    return p.fail(.{ .syntax_error = "'yield' is not a valid identifier name in a generator" }, t);
                }
                // `this`, `new`, `typeof`, `function`, … start constructs ZQJS lacks;
                // `let` as a variable name is legal sloppy JS we choose not to support.
                if (std.mem.eql(u8, name, "finally"))
                    return p.fail(.{ .syntax_error = "unexpected token 'finally'" }, t);
                if (token.reserved_identifiers.has(name) or std.mem.eql(u8, name, "let"))
                    return p.fail(.{ .unsupported = .syntax }, t);
                try p.advance();
                const id = p.ref_count;
                p.ref_count += 1;
                return p.node(s, .{ .identifier = .{ .name = name, .span = s, .id = id } }, 0);
            },
            .l_paren => {
                const res = try p.parseParenList();
                return p.finishParenAsExpr(res);
            },
            .slash, .slash_eq => return p.regexpLiteral(),
            // Tokens that cannot begin an expression in any JavaScript.
            .eof, .semicolon, .r_paren, .r_bracket, .r_brace, .comma, .star, .star_star, .percent, .eq3, .neq3, .eq2, .neq2, .lt, .le, .gt, .ge, .shl, .shr, .ushr, .amp, .pipe, .caret, .amp_amp, .pipe_pipe, .question2, .question, .question_dot, .colon, .eq, .arrow, .plus_eq, .minus_eq, .star_eq, .percent_eq, .star_star_eq, .shl_eq, .shr_eq, .ushr_eq, .amp_eq, .pipe_eq, .caret_eq, .amp_amp_eq, .pipe_pipe_eq, .question2_eq => return p.fail(.{ .syntax_error = "unexpected token" }, t),
            // `[`, `{`, `...`, keywords, … may start valid JS.
            .private_ident => return p.fail(.{ .syntax_error = "Private identifiers cannot be used here" }, t),
            else => return p.fail(.{ .unsupported = .syntax }, t),
        }
    }

    /// `t` follows a complete expression but is not what the grammar expects.
    /// It is a SyntaxError only if no JavaScript operator or construct can follow an
    /// expression with this token (and, at statement level, ASI does not apply).
    fn unexpectedAfterExpression(p: *Parser, t: Token) Error {
        const certain = switch (t.tag) {
            .number, .string, .kw_true, .kw_false, .kw_null, .r_paren, .r_bracket, .r_brace, .semicolon, .eof, .arrow => true,
            // `in` and `instanceof` are binary operators; `async function` is valid JS.
            .identifier => !p.isText(t, "in") and !p.isText(t, "instanceof") and !p.isText(t, "function"),
            else => false,
        };
        if (certain) return p.fail(.{ .syntax_error = "unexpected token" }, t);
        return p.fail(.{ .unsupported = .syntax }, t);
    }

    fn node(p: *Parser, s: ast.Span, data: ast.Expr.Data, child_depth: u16) Error!*const ast.Expr {
        const depth = @as(u32, child_depth) + 1;
        if (depth > p.limits.max_nesting_depth) return p.limitExceeded(s.start, s.end);
        const e = try p.arena.create(ast.Expr);
        e.* = .{ .span = s, .depth = @intCast(depth), .data = data };
        return e;
    }

    fn patNode(p: *Parser, s: ast.Span, data: ast.Pattern.Data, child_depth: u16) Error!*const ast.Pattern {
        const depth = @as(u32, child_depth) + 1;
        if (depth > p.limits.max_nesting_depth) return p.limitExceeded(s.start, s.end);
        const pat = try p.arena.create(ast.Pattern);
        pat.* = .{ .span = s, .depth = @intCast(depth), .data = data };
        return pat;
    }

    fn rejectCoverExpr(p: *Parser, e: *const ast.Expr) Error!void {
        if (e.has_cover_init) return p.failAt(.{ .syntax_error = "invalid shorthand property initializer" }, p.cover_init_span.start, p.cover_init_span.end);
        if (e.has_hole) return p.failAt(.{ .unsupported = .sparse_array }, p.hole_span.start, p.hole_span.end);
    }

    fn exprToAssignPattern(p: *Parser, e: *const ast.Expr) Error!*const ast.Pattern {
        try p.enter();
        defer p.depth -= 1;
        switch (e.data) {
            .identifier => |r| {
                try p.rejectCoverExpr(e);
                return p.patNode(e.span, .{ .target = .{ .ref = r } }, 0);
            },
            .member => |m| {
                try p.rejectCoverExpr(e);
                return p.patNode(e.span, .{ .target = .{ .member = m } }, 0);
            },
            .array => |items| {
                if (e.has_rest_trailing_comma) return p.failAt(.{ .syntax_error = "rest element must be last element" }, e.span.end - 1, e.span.end);
                var elems: std.ArrayList(?ast.Pattern.Elem) = .empty;
                var rest: ?*const ast.Pattern = null;
                var max_depth: u16 = 0;
                for (items, 0..) |item, i| {
                    switch (item.data) {
                        .hole => try elems.append(p.arena, null),
                        .spread => |inner| {
                            if (i != items.len - 1) return p.failAt(.{ .syntax_error = "rest element must be last element" }, item.span.start, item.span.end);
                            if (inner.data == .assign or inner.data == .assign_pattern)
                                return p.failAt(.{ .syntax_error = "rest element may not have a default initializer" }, inner.span.start, inner.span.end);
                            const r = try p.exprToAssignPattern(inner);
                            max_depth = @max(max_depth, r.depth);
                            rest = r;
                        },
                        .assign => |a| {
                            if (a.op != .plain) return p.failAt(.{ .syntax_error = "invalid destructuring assignment target" }, item.span.start, item.span.end);
                            const pat = try p.patNode(item.span, .{ .target = a.target }, 0);
                            max_depth = @max(max_depth, pat.depth);
                            try elems.append(p.arena, .{ .pattern = pat, .default = a.value, .span = item.span });
                        },
                        .assign_pattern => |ap| {
                            max_depth = @max(max_depth, ap.pattern.depth);
                            try elems.append(p.arena, .{ .pattern = ap.pattern, .default = ap.value, .span = item.span });
                        },
                        else => {
                            const pat = try p.exprToAssignPattern(item);
                            max_depth = @max(max_depth, pat.depth);
                            try elems.append(p.arena, .{ .pattern = pat, .default = null, .span = item.span });
                        },
                    }
                }
                return p.patNode(e.span, .{ .array = .{ .elems = elems.items, .rest = rest } }, max_depth);
            },
            .object => |props| {
                if (e.has_rest_trailing_comma) return p.failAt(.{ .syntax_error = "rest element must be last element" }, e.span.end - 1, e.span.end);
                var out: std.ArrayList(ast.Pattern.Prop) = .empty;
                var rest: ?*const ast.Pattern = null;
                var max_depth: u16 = 0;
                for (props, 0..) |prop, i| {
                    switch (prop) {
                        .spread => |sp| {
                            if (i != props.len - 1) return p.failAt(.{ .syntax_error = "rest element must be last element" }, sp.span.start, sp.span.end);
                            if (sp.expr.data == .assign or sp.expr.data == .assign_pattern)
                                return p.failAt(.{ .syntax_error = "rest element may not have a default initializer" }, sp.span.start, sp.span.end);
                            if (sp.expr.data != .identifier and sp.expr.data != .member)
                                return p.invalidTarget(sp.expr, "invalid rest assignment target");
                            const r = try p.exprToAssignPattern(sp.expr);
                            max_depth = @max(max_depth, r.depth);
                            rest = r;
                        },
                        .cover_init => |ci| {
                            inferExprName(ci.default, ci.ref.name);
                            const pat = try p.patNode(ci.ref.span, .{ .target = .{ .ref = ci.ref } }, 0);
                            try out.append(p.arena, .{ .key = .{ .name = ci.ref.name }, .pattern = pat, .default = ci.default, .shorthand = true, .span = ci.span });
                        },
                        .prop => |pr| {
                            if (pr.kind != .init) return p.failAt(.{ .syntax_error = "invalid destructuring assignment target" }, pr.span.start, pr.span.end);
                            if (pr.shorthand) {
                                const pat = try p.exprToAssignPattern(pr.value);
                                try out.append(p.arena, .{ .key = pr.key, .pattern = pat, .default = null, .shorthand = true, .span = pr.span });
                            } else {
                                var default: ?*const ast.Expr = null;
                                const pat: *const ast.Pattern = switch (pr.value.data) {
                                    .assign => |a| blk: {
                                        if (a.op != .plain) return p.failAt(.{ .syntax_error = "invalid destructuring assignment target" }, pr.value.span.start, pr.value.span.end);
                                        default = a.value;
                                        break :blk try p.patNode(pr.value.span, .{ .target = a.target }, 0);
                                    },
                                    .assign_pattern => |ap| blk: {
                                        default = ap.value;
                                        break :blk ap.pattern;
                                    },
                                    else => try p.exprToAssignPattern(pr.value),
                                };
                                max_depth = @max(max_depth, pat.depth);
                                try out.append(p.arena, .{ .key = pr.key, .pattern = pat, .default = default, .shorthand = false, .span = pr.span });
                            }
                        },
                    }
                }
                return p.patNode(e.span, .{ .object = .{ .props = out.items, .rest = rest } }, max_depth);
            },
            else => return p.invalidTarget(e, "invalid assignment target"),
        }
    }

    fn refToDeclarator(p: *Parser, r: ast.Ref) Error!ast.Declarator {
        if (token.reserved_identifiers.has(r.name))
            return p.failAt(.{ .syntax_error = "reserved word cannot be a binding name" }, r.span.start, r.span.end);
        if (std.mem.eql(u8, r.name, "let")) return p.failAt(.{ .unsupported = .syntax }, r.span.start, r.span.end);
        if (std.mem.eql(u8, r.name, "arguments")) return p.failAt(.{ .unsupported = .arguments }, r.span.start, r.span.end);
        const d: ast.Declarator = .{ .name = r.name, .span = r.span, .binding = p.binding_count, .init = null };
        p.binding_count += 1;
        return d;
    }

    fn targetPatternToBindingPattern(p: *Parser, pat: *const ast.Pattern) Error!*const ast.Pattern {
        try p.enter();
        defer p.depth -= 1;
        switch (pat.data) {
            .binding => return pat,
            .target => |t| switch (t) {
                .ref => |r| {
                    const d = try p.refToDeclarator(r);
                    return p.patNode(pat.span, .{ .binding = d }, 0);
                },
                .member, .super_member => return p.failAt(.{ .syntax_error = "invalid binding pattern" }, pat.span.start, pat.span.end),
            },
            .array => |arr| {
                var elems: std.ArrayList(?ast.Pattern.Elem) = .empty;
                var max_depth: u16 = 0;
                for (arr.elems) |maybe| {
                    const el = maybe orelse {
                        try elems.append(p.arena, null);
                        continue;
                    };
                    const sub = try p.targetPatternToBindingPattern(el.pattern);
                    if (el.default) |def| if (sub.data == .binding) inferExprName(def, sub.data.binding.name);
                    max_depth = @max(max_depth, sub.depth);
                    try elems.append(p.arena, .{ .pattern = sub, .default = el.default, .span = el.span });
                }
                const rest = if (arr.rest) |r| blk: {
                    const sr = try p.targetPatternToBindingPattern(r);
                    max_depth = @max(max_depth, sr.depth);
                    break :blk sr;
                } else null;
                return p.patNode(pat.span, .{ .array = .{ .elems = elems.items, .rest = rest } }, max_depth);
            },
            .object => |obj| {
                var props: std.ArrayList(ast.Pattern.Prop) = .empty;
                var max_depth: u16 = 0;
                for (obj.props) |pr| {
                    const sub = try p.targetPatternToBindingPattern(pr.pattern);
                    if (pr.default) |def| if (sub.data == .binding) inferExprName(def, sub.data.binding.name);
                    max_depth = @max(max_depth, sub.depth);
                    try props.append(p.arena, .{ .key = pr.key, .pattern = sub, .default = pr.default, .shorthand = pr.shorthand, .span = pr.span });
                }
                const rest = if (obj.rest) |r| blk: {
                    if (r.data != .target or r.data.target != .ref)
                        return p.failAt(.{ .syntax_error = "rest element must be an identifier" }, r.span.start, r.span.end);
                    const sr = try p.targetPatternToBindingPattern(r);
                    max_depth = @max(max_depth, sr.depth);
                    break :blk sr;
                } else null;
                return p.patNode(pat.span, .{ .object = .{ .props = props.items, .rest = rest } }, max_depth);
            },
        }
    }

    fn exprToBindingPattern(p: *Parser, e: *const ast.Expr) Error!*const ast.Pattern {
        const tp = try p.exprToAssignPattern(e);
        return p.targetPatternToBindingPattern(tp);
    }

    fn exprToArrowParam(p: *Parser, e: *const ast.Expr, item_span: ast.Span) Error!ast.Param {
        switch (e.data) {
            .assign => |a| {
                if (a.op != .plain or a.target != .ref)
                    return p.failAt(.{ .syntax_error = "invalid arrow function parameter" }, item_span.start, item_span.end);
                const d = try p.refToDeclarator(a.target.ref);
                inferExprName(a.value, d.name);
                const pat = try p.patNode(d.span, .{ .binding = d }, 0);
                return .{ .pattern = pat, .default = a.value, .is_rest = false, .span = item_span };
            },
            .assign_pattern => |ap| {
                const pat = try p.targetPatternToBindingPattern(ap.pattern);
                return .{ .pattern = pat, .default = ap.value, .is_rest = false, .span = item_span };
            },
            else => {
                const pat = try p.exprToBindingPattern(e);
                return .{ .pattern = pat, .default = null, .is_rest = false, .span = item_span };
            },
        }
    }

    fn fail(p: *Parser, detail: Diagnostic.Detail, t: Token) Error {
        return p.failAt(detail, t.start, t.end);
    }

    fn failAt(p: *Parser, detail: Diagnostic.Detail, start: usize, end: usize) Error {
        p.lexer.diag.* = .{ .detail = detail, .start = @intCast(start), .end = @intCast(end) };
        return switch (detail) {
            .syntax_error => error.SyntaxError,
            .unsupported => error.Unsupported,
            .limit_exceeded => error.LimitExceeded,
        };
    }

    fn limitExceeded(p: *Parser, start: u32, end: u32) Error {
        return p.failAt(.{ .limit_exceeded = .nesting_depth }, start, end);
    }

    fn regexpLiteral(p: *Parser) Error!*const ast.Expr {
        const start = p.tok.start;
        const scanned = try p.lexer.scanRegExp(start);
        const s: ast.Span = .{ .start = start, .end = scanned.end };

        var out: std.ArrayList(u16) = .empty;
        try out.ensureTotalCapacityPrecise(p.arena, scanned.pattern.len);
        var i: usize = 0;
        while (i < scanned.pattern.len) {
            const c = scanned.pattern[i];
            if (c < 0x80) {
                out.appendAssumeCapacity(c);
                i += 1;
            } else {
                const cp, const len = try p.decodeUtf8(scanned.pattern, i, start + 1);
                appendCodePoint(&out, cp);
                i += len;
            }
        }

        var rx_diag: regex.Diagnostic = .{};
        const parsed_flags = regex.parseFlagsAscii(scanned.flags, &rx_diag) catch |err| {
            return p.failRegExp(err, rx_diag, s);
        };
        var prog = regex.compileWithDepth(p.arena, out.items, parsed_flags.flags, p.limits.max_nesting_depth, &rx_diag) catch |err| {
            return p.failRegExp(err, rx_diag, s);
        };
        prog.deinit(p.arena);

        try p.advance();
        return p.node(s, .{ .regexp = .{ .pattern = out.items, .flags = scanned.flags } }, 0);
    }

    fn failRegExp(p: *Parser, err: regex.CompileError, rx_diag: regex.Diagnostic, s: ast.Span) Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SyntaxError => p.failAt(.{ .syntax_error = rx_diag.message }, s.start, s.end),
            error.TooComplex => p.failAt(.{ .limit_exceeded = rx_diag.limit }, s.start, s.end),
            error.Unsupported => {
                const feat = if (rx_diag.feature) |f_name|
                    std.meta.stringToEnum(Feature, f_name) orelse .syntax
                else
                    .syntax;
                return p.failAt(.{ .unsupported = feat }, s.start, s.end);
            },
        };
    }

    fn templateLiteral(p: *Parser) Error!*const ast.Expr {
        try p.enter();
        defer p.depth -= 1;

        const start = p.tok.start;
        var quasis: std.ArrayList([]const u16) = .empty;
        var exprs: std.ArrayList(*const ast.Expr) = .empty;
        var max_depth: u16 = 0;

        if (p.tok.tag == .template_no_sub) {
            const t = p.tok;
            try quasis.append(p.arena, try p.decodeEscapes(p.source()[t.start + 1 .. t.end - 1], t.start + 1, true));
            try p.advance();
            return p.node(span(t, t), .{ .template = .{ .quasis = quasis.items, .exprs = exprs.items } }, 0);
        }

        // `.template_head`: ends with `${`
        const head = p.tok;
        try quasis.append(p.arena, try p.decodeEscapes(p.source()[head.start + 1 .. head.end - 2], head.start + 1, true));
        try p.advance();

        while (true) {
            const expr = try p.nested();
            max_depth = @max(max_depth, expr.depth);
            try exprs.append(p.arena, expr);

            if (p.tok.tag != .r_brace) return p.unexpectedAfterExpression(p.tok);
            // Lex the rest of the template starting right after `}`, before advancing.
            p.tok = try p.lexer.nextTemplatePart();
            const part = p.tok;
            if (part.tag == .template_tail) {
                try quasis.append(p.arena, try p.decodeEscapes(p.source()[part.start .. part.end - 1], part.start, true));
                try p.advance();
                return p.node(.{ .start = start, .end = part.end }, .{ .template = .{ .quasis = quasis.items, .exprs = exprs.items } }, max_depth);
            }
            // `.template_middle`: ends with `${`
            try quasis.append(p.arena, try p.decodeEscapes(p.source()[part.start .. part.end - 2], part.start, true));
            try p.advance();
        }
    }

    fn taggedTemplate(p: *Parser, callee: *const ast.Expr) Error!*const ast.Expr {
        try p.enter();
        defer p.depth -= 1;

        var cooked: std.ArrayList(?[]const u16) = .empty;
        var raw: std.ArrayList([]const u16) = .empty;
        var exprs: std.ArrayList(*const ast.Expr) = .empty;
        var max_depth: u16 = callee.depth;

        if (p.tok.tag == .template_no_sub) {
            const t = p.tok;
            const slice = p.source()[t.start + 1 .. t.end - 1];
            try raw.append(p.arena, try p.decodeRawTemplate(slice, t.start + 1));
            try cooked.append(p.arena, try p.decodeEscapesOptional(slice, t.start + 1, true, true));
            try p.advance();
            return p.node(.{ .start = callee.span.start, .end = t.end }, .{ .tagged_template = .{
                .callee = callee,
                .cooked = cooked.items,
                .raw = raw.items,
                .exprs = exprs.items,
            } }, max_depth);
        }

        const head = p.tok;
        const head_slice = p.source()[head.start + 1 .. head.end - 2];
        try raw.append(p.arena, try p.decodeRawTemplate(head_slice, head.start + 1));
        try cooked.append(p.arena, try p.decodeEscapesOptional(head_slice, head.start + 1, true, true));
        try p.advance();

        while (true) {
            const expr = try p.nested();
            max_depth = @max(max_depth, expr.depth);
            try exprs.append(p.arena, expr);

            if (p.tok.tag != .r_brace) return p.unexpectedAfterExpression(p.tok);
            p.tok = try p.lexer.nextTemplatePart();
            const part = p.tok;
            if (part.tag == .template_tail) {
                const slice = p.source()[part.start .. part.end - 1];
                try raw.append(p.arena, try p.decodeRawTemplate(slice, part.start));
                try cooked.append(p.arena, try p.decodeEscapesOptional(slice, part.start, true, true));
                try p.advance();
                return p.node(.{ .start = callee.span.start, .end = part.end }, .{ .tagged_template = .{
                    .callee = callee,
                    .cooked = cooked.items,
                    .raw = raw.items,
                    .exprs = exprs.items,
                } }, max_depth);
            }
            const slice = p.source()[part.start .. part.end - 2];
            try raw.append(p.arena, try p.decodeRawTemplate(slice, part.start));
            try cooked.append(p.arena, try p.decodeEscapesOptional(slice, part.start, true, true));
            try p.advance();
        }
    }

    fn decodeRawTemplate(p: *Parser, s: []const u8, base: u32) Error![]const u16 {
        var out: std.ArrayList(u16) = .empty;
        try out.ensureTotalCapacityPrecise(p.arena, s.len);
        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];
            if (c >= 0x80) {
                const cp, const len = try p.decodeUtf8(s, i, base);
                appendCodePoint(&out, cp);
                i += len;
                continue;
            }
            if (c == '\r') {
                out.appendAssumeCapacity('\n');
                i += if (i + 1 < s.len and s[i + 1] == '\n') 2 else 1;
                continue;
            }
            out.appendAssumeCapacity(c);
            i += 1;
        }
        return out.items;
    }

    /// Decodes a string literal token (quotes included) to UTF-16 code units
    /// (LANGUAGE.md §3). The lexer has already found the closing quote.
    fn decodeString(p: *Parser, t: Token) Error![]const u16 {
        const base = t.start + 1;
        return p.decodeEscapes(p.source()[base .. t.end - 1], base, false);
    }

    fn decodeEscapes(p: *Parser, s: []const u8, base: u32, is_template: bool) Error![]const u16 {
        return (try p.decodeEscapesOptional(s, base, is_template, false)).?;
    }

    fn decodeEscapesOptional(p: *Parser, s: []const u8, base: u32, is_template: bool, allow_invalid: bool) Error!?[]const u16 {
        var out: std.ArrayList(u16) = .empty;
        // Every source byte yields at most one code unit (a 4-byte UTF-8 sequence or a
        // `\u{…}` escape yields two), so one allocation suffices.
        try out.ensureTotalCapacityPrecise(p.arena, s.len);

        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];
            if (c >= 0x80) {
                const cp, const len = try p.decodeUtf8(s, i, base);
                appendCodePoint(&out, cp);
                i += len;
                continue;
            }
            if (is_template and c == '\r') {
                // JS template TV normalizes raw CR and CRLF to LF.
                out.appendAssumeCapacity('\n');
                i += if (i + 1 < s.len and s[i + 1] == '\n') 2 else 1;
                continue;
            }
            if (c != '\\') {
                out.appendAssumeCapacity(c);
                i += 1;
                continue;
            }
            const esc_start = base + i;
            i += 1; // the lexer guarantees a character follows `\`
            const e = s[i];
            i += 1;
            switch (e) {
                'b' => out.appendAssumeCapacity(0x08),
                'f' => out.appendAssumeCapacity(0x0C),
                'n' => out.appendAssumeCapacity('\n'),
                'r' => out.appendAssumeCapacity('\r'),
                't' => out.appendAssumeCapacity('\t'),
                'v' => out.appendAssumeCapacity(0x0B),
                '0' => {
                    if (i < s.len and std.ascii.isDigit(s[i])) {
                        if (allow_invalid) return null;
                        return p.failAt(.{ .unsupported = .legacy_octal }, esc_start, base + i + 1);
                    }
                    out.appendAssumeCapacity(0);
                },
                '1'...'9' => {
                    if (allow_invalid) return null;
                    return p.failAt(.{ .unsupported = .legacy_octal }, esc_start, base + i);
                },
                'x' => {
                    const hi = hexAt(s, i) orelse {
                        if (allow_invalid) return null;
                        return p.failAt(.{ .syntax_error = "invalid hexadecimal escape" }, esc_start, base + i);
                    };
                    const lo = hexAt(s, i + 1) orelse {
                        if (allow_invalid) return null;
                        return p.failAt(.{ .syntax_error = "invalid hexadecimal escape" }, esc_start, base + i);
                    };
                    out.appendAssumeCapacity(hi * 16 + lo);
                    i += 2;
                },
                'u' => if (i < s.len and s[i] == '{') {
                    i += 1;
                    var cp: u32 = 0;
                    var n: usize = 0;
                    while (i < s.len and s[i] != '}') : ({
                        i += 1;
                        n += 1;
                    }) {
                        const d = hexAt(s, i) orelse {
                            if (allow_invalid) return null;
                            return p.failAt(.{ .syntax_error = "invalid Unicode escape" }, esc_start, base + i);
                        };
                        cp = @min(cp * 16 + d, 0x110000); // saturate: cp * 16 can't overflow
                    }
                    if (i >= s.len or n == 0) {
                        if (allow_invalid) return null;
                        return p.failAt(.{ .syntax_error = "invalid Unicode escape" }, esc_start, base + i);
                    }
                    i += 1; // `}`
                    if (cp > 0x10FFFF) {
                        if (allow_invalid) return null;
                        return p.failAt(.{ .syntax_error = "Unicode escape above U+10FFFF" }, esc_start, base + i);
                    }
                    appendCodePoint(&out, @intCast(cp));
                } else {
                    var unit: u16 = 0;
                    for (0..4) |k| {
                        const d = hexAt(s, i + k) orelse {
                            if (allow_invalid) return null;
                            return p.failAt(.{ .syntax_error = "invalid Unicode escape" }, esc_start, base + i);
                        };
                        unit = unit * 16 + d;
                    }
                    out.appendAssumeCapacity(unit); // lone surrogates are allowed
                    i += 4;
                },
                // Line continuations produce nothing.
                '\n' => {},
                '\r' => {
                    if (i < s.len and s[i] == '\n') i += 1;
                },
                0x80...0xFF => {
                    const cp, const len = try p.decodeUtf8(s, i - 1, base);
                    i += len - 1;
                    if (cp != 0x2028 and cp != 0x2029) appendCodePoint(&out, cp);
                },
                else => out.appendAssumeCapacity(e), // identity escape: `\q` is `q`
            }
        }
        return out.items;
    }

    fn decodeUtf8(p: *Parser, s: []const u8, i: usize, base: u32) Error!struct { u21, usize } {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch
            return p.failAt(.{ .unsupported = .invalid_utf8 }, base + i, base + i + 1);
        if (i + len > s.len) return p.failAt(.{ .unsupported = .invalid_utf8 }, base + i, base + s.len);
        const cp = std.unicode.utf8Decode(s[i..][0..len]) catch
            return p.failAt(.{ .unsupported = .invalid_utf8 }, base + i, base + i + len);
        return .{ cp, len };
    }

    fn parseClass(p: *Parser, kind: @FieldType(ast.Class, "kind")) Error!*const ast.Class {
        try p.enter();
        defer p.depth -= 1;

        const start = p.tok.start;
        try p.advance(); // `class`
        const class_id = p.class_count;
        p.class_count += 1;

        var name_decl: ?ast.Declarator = null;
        if (kind == .declaration) {
            name_decl = try p.bindingName(true);
        } else if (p.tok.tag == .identifier and !p.isText(p.tok, "extends")) {
            name_decl = try p.bindingName(true);
        }

        var super_class: ?*const ast.Expr = null;
        if (p.isText(p.tok, "extends")) {
            try p.advance();
            const base = if (p.tok.tag == .identifier and p.isText(p.tok, "new"))
                try p.newExpr()
            else
                try p.members(try p.primary());
            super_class = try p.calls(base);
        }
        const has_super = super_class != null;

        if (p.tok.tag != .l_brace) return p.fail(.{ .syntax_error = "expected '{'" }, p.tok);
        const open_brace = p.tok;
        try p.advance(); // `{`

        var explicit_ctor: ?*const ast.Function = null;
        var methods: std.ArrayList(ast.ClassMethod) = .empty;
        var instance_fields: std.ArrayList(ast.ClassField) = .empty;
        var static_fields: std.ArrayList(ast.ClassField) = .empty;
        var static_items: std.ArrayList(ast.ClassStaticItem) = .empty;

        while (p.tok.tag != .r_brace) {
            if (p.tok.tag == .eof) return p.fail(.{ .syntax_error = "unterminated class body" }, open_brace);
            if (p.tok.tag == .semicolon) {
                try p.advance();
                continue;
            }
            const elem_start = p.tok.start;
            var is_static = false;
            if (p.isText(p.tok, "static")) {
                const next = try p.peek();
                if (next.tag != .l_paren and next.tag != .semicolon and next.tag != .r_brace and next.tag != .eq) {
                    is_static = true;
                    try p.advance();
                }
            }
            if (is_static and p.tok.tag == .l_brace) {
                const fn_id = p.function_count;
                p.function_count += 1;
                const outer_loops = p.loop_depth;
                const outer_switches = p.switch_depth;
                const outer_labels = p.labels;
                const outer_derived = p.in_derived_ctor;
                const outer_method = p.in_class_method;
                const outer_async_ctx = p.async_ctx;
                const outer_yield_ctx = p.yield_ctx;
                p.loop_depth = 0;
                p.switch_depth = 0;
                p.labels = .empty;
                p.in_derived_ctor = .none;
                p.in_class_method = true;
                p.async_ctx = .none;
                p.yield_ctx = .none;
                p.function_depth += 1;
                defer {
                    p.loop_depth = outer_loops;
                    p.switch_depth = outer_switches;
                    p.labels = outer_labels;
                    p.in_derived_ctor = outer_derived;
                    p.in_class_method = outer_method;
                    p.async_ctx = outer_async_ctx;
                    p.yield_ctx = outer_yield_ctx;
                    p.function_depth -= 1;
                }
                const parsed_body = try p.parseFunctionBody();
                const blk_fn = try p.arena.create(ast.Function);
                blk_fn.* = .{
                    .span = .{ .start = elem_start, .end = parsed_body.end },
                    .id = fn_id,
                    .kind = .expression,
                    .is_arrow = false,
                    .is_async = false,
                    .is_method = true,
                    .has_home_object = true,
                    .length = 0,
                    .name = null,
                    .inferred_name = "<static_block>",
                    .params = &.{},
                    .body = parsed_body.body,
                };
                try static_items.append(p.arena, .{ .block = blk_fn });
                continue;
            }
            var is_async = false;
            var is_generator = false;
            var method_kind: @FieldType(ast.ClassMethod, "kind") = .method;
            if (p.isText(p.tok, "async")) {
                const next = try p.peek();
                if (!next.newline_before and next.tag != .l_paren and next.tag != .eq and next.tag != .semicolon and next.tag != .r_brace) {
                    is_async = true;
                    try p.advance();
                }
            } else if (p.isText(p.tok, "get") or p.isText(p.tok, "set")) {
                const next = try p.peek();
                if (next.tag != .l_paren and next.tag != .semicolon and next.tag != .r_brace and next.tag != .eq) {
                    method_kind = if (p.isText(p.tok, "get")) .getter else .setter;
                    try p.advance();
                }
            }
            if (p.tok.tag == .star) {
                if (method_kind != .method) return p.fail(.{ .syntax_error = "unexpected '*'" }, p.tok);
                is_generator = true;
                try p.advance();
            }
            const key_tok = p.tok;
            const is_private = p.tok.tag == .private_ident;
            const key: ast.PropertyKey = switch (p.tok.tag) {
                .private_ident => blk: {
                    const name = p.tok.text(p.source());
                    if (std.mem.eql(u8, name, "#constructor")) {
                        return p.fail(.{ .syntax_error = "Classes may not have a private element named '#constructor'" }, key_tok);
                    }
                    try p.advance();
                    break :blk .{ .name = name };
                },
                .l_bracket => try p.computedPropertyKey(),
                .string => blk: {
                    const units = try p.decodeString(p.tok);
                    try p.advance();
                    break :blk .{ .string = units };
                },
                .number => blk: {
                    const val = try number.literalValue(p.arena, p.tok.text(p.source()));
                    try p.advance();
                    break :blk .{ .number = val };
                },
                else => blk: {
                    const prop_tok = try p.expectPropertyName();
                    break :blk .{ .name = prop_tok.text(p.source()) };
                },
            };

            const is_ctor = !is_static and !is_private and key == .name and std.mem.eql(u8, key.name, "constructor");
            if (is_ctor and is_async) {
                return p.fail(.{ .syntax_error = "class constructor may not be an async method" }, key_tok);
            }
            if (is_ctor and is_generator) {
                return p.fail(.{ .syntax_error = "class constructor may not be a generator method" }, key_tok);
            }
            if (is_ctor and method_kind != .method) {
                return p.fail(.{ .syntax_error = "class constructor may not be an accessor" }, key_tok);
            }
            if (is_ctor and explicit_ctor != null) {
                return p.fail(.{ .syntax_error = "a class may only have one constructor" }, key_tok);
            }
            if (is_static and !is_private and key == .name and std.mem.eql(u8, key.name, "prototype")) {
                return p.fail(.{ .syntax_error = "classes may not have a static property named 'prototype'" }, key_tok);
            }
            if (p.tok.tag != .l_paren) {
                if (is_async or is_generator or method_kind != .method) {
                    return p.fail(.{ .syntax_error = "expected '('" }, p.tok);
                }
                if (is_ctor) {
                    return p.fail(.{ .syntax_error = "Classes may not have a field named 'constructor'" }, key_tok);
                }
                var init_fn: ?*const ast.Function = null;
                var field_end = key_tok.end;
                if (p.tok.tag == .eq) {
                    try p.advance();
                    const fn_id = p.function_count;
                    p.function_count += 1;
                    const outer_derived = p.in_derived_ctor;
                    const outer_method = p.in_class_method;
                    const outer_async_ctx = p.async_ctx;
                    const outer_yield_ctx = p.yield_ctx;
                    p.in_derived_ctor = .none;
                    p.in_class_method = true;
                    p.async_ctx = .none;
                    p.yield_ctx = .none;
                    p.function_depth += 1;
                    defer {
                        p.in_derived_ctor = outer_derived;
                        p.in_class_method = outer_method;
                        p.async_ctx = outer_async_ctx;
                        p.yield_ctx = outer_yield_ctx;
                        p.function_depth -= 1;
                    }
                    const init_expr = try p.nested();
                    field_end = init_expr.span.end;
                    const body = try p.arena.alloc(ast.Stmt, 1);
                    body[0] = .{ .span = init_expr.span, .data = .{ .@"return" = init_expr } };
                    const f = try p.arena.create(ast.Function);
                    f.* = .{
                        .span = .{ .start = elem_start, .end = field_end },
                        .id = fn_id,
                        .kind = .expression,
                        .is_arrow = false,
                        .is_async = false,
                        .is_method = true,
                        .has_home_object = true,
                        .length = 0,
                        .name = null,
                        .inferred_name = "",
                        .params = &.{},
                        .body = body,
                    };
                    init_fn = f;
                }
                if (p.tok.tag == .semicolon) {
                    field_end = p.tok.end;
                    try p.advance();
                } else if (p.tok.tag != .r_brace and !p.tok.newline_before) {
                    return p.fail(.{ .syntax_error = "expected ';' after class field" }, p.tok);
                }
                const field: ast.ClassField = .{
                    .key = key,
                    .is_static = is_static,
                    .is_private = is_private,
                    .init = init_fn,
                    .span = .{ .start = elem_start, .end = field_end },
                };
                if (is_static) {
                    const idx = static_fields.items.len;
                    try static_fields.append(p.arena, field);
                    try static_items.append(p.arena, .{ .field = idx });
                } else {
                    try instance_fields.append(p.arena, field);
                }
                continue;
            }

            const fn_id = p.function_count;
            p.function_count += 1;

            const outer_async_ctx = p.async_ctx;
            const outer_yield_ctx = p.yield_ctx;
            p.async_ctx = if (is_async) .params else .none;
            p.yield_ctx = if (is_generator) .params else .none;
            defer {
                p.async_ctx = outer_async_ctx;
                p.yield_ctx = outer_yield_ctx;
            }
            const params = try p.parseParams();
            if (method_kind != .method) {
                try p.validateAccessorParams(method_kind == .getter, params, key_tok);
            }

            if (p.tok.tag != .l_brace) return p.fail(.{ .syntax_error = "expected '{'" }, p.tok);
            const outer_loops = p.loop_depth;
            const outer_switches = p.switch_depth;
            const outer_labels = p.labels;
            const outer_derived = p.in_derived_ctor;
            const outer_method = p.in_class_method;
            p.loop_depth = 0;
            p.switch_depth = 0;
            p.labels = .empty;
            p.in_derived_ctor = if (is_ctor and has_super) .direct else .none;
            p.in_class_method = true;
            p.function_depth += 1;
            p.async_ctx = if (is_async) .body else .none;
            p.yield_ctx = if (is_generator) .body else .none;
            defer {
                p.loop_depth = outer_loops;
                p.switch_depth = outer_switches;
                p.labels = outer_labels;
                p.in_derived_ctor = outer_derived;
                p.in_class_method = outer_method;
                p.function_depth -= 1;
            }
            const parsed_body = try p.parseFunctionBody();

            const f = try p.arena.create(ast.Function);
            f.* = .{
                .span = .{ .start = elem_start, .end = parsed_body.end },
                .id = fn_id,
                .kind = .expression,
                .is_arrow = false,
                .is_async = is_async,
                .is_generator = is_generator,
                .is_method = !is_ctor,
                .is_class_constructor = is_ctor,
                .has_super_ctor = is_ctor and has_super,
                .has_home_object = true,
                .length = paramLength(params),
                .name = null,
                .inferred_name = switch (key) {
                    .name => |n| n,
                    else => "",
                },
                .params = params,
                .body = parsed_body.body,
            };
            if (is_ctor) {
                if (name_decl) |nd| f.inferred_name = nd.name;
                explicit_ctor = f;
            } else {
                try methods.append(p.arena, .{
                    .key = key,
                    .is_static = is_static,
                    .is_private = is_private,
                    .kind = method_kind,
                    .func = f,
                    .span = .{ .start = elem_start, .end = parsed_body.end },
                });
            }
        }
        const close_brace = p.tok;
        try p.advance(); // `}`

        const ctor = explicit_ctor orelse try p.synthDefaultCtor(.{ .start = start, .end = close_brace.end }, name_decl, has_super);
        const cls = try p.arena.create(ast.Class);
        cls.* = .{
            .span = .{ .start = start, .end = close_brace.end },
            .id = class_id,
            .kind = kind,
            .name = name_decl,
            .super_class = super_class,
            .constructor = ctor,
            .methods = methods.items,
            .instance_fields = instance_fields.items,
            .static_fields = static_fields.items,
            .static_items = static_items.items,
        };
        return cls;
    }

    fn synthDefaultCtor(p: *Parser, sp: ast.Span, name_decl: ?ast.Declarator, has_super: bool) Error!*const ast.Function {
        const fn_id = p.function_count;
        p.function_count += 1;
        const f = try p.arena.create(ast.Function);
        if (!has_super) {
            f.* = .{
                .span = sp,
                .id = fn_id,
                .kind = .expression,
                .is_class_constructor = true,
                .has_home_object = true,
                .name = null,
                .inferred_name = if (name_decl) |nd| nd.name else "",
                .params = &.{},
                .body = &.{},
            };
            return f;
        }
        // Derived default constructor: `constructor(...args) { super(...args); }`
        const rest_decl: ast.Declarator = .{
            .name = "args",
            .span = sp,
            .binding = p.binding_count,
            .init = null,
        };
        p.binding_count += 1;
        const pat = try p.patNode(sp, .{ .binding = rest_decl }, 0);
        const params = try p.arena.alloc(ast.Param, 1);
        params[0] = .{ .pattern = pat, .default = null, .is_rest = true, .span = sp };

        const ref_id = p.ref_count;
        p.ref_count += 1;
        const args_ident = try p.node(sp, .{ .identifier = .{ .name = "args", .span = sp, .id = ref_id } }, 0);
        const spread_arg = try p.node(sp, .{ .spread = args_ident }, 0);
        const call_args = try p.arena.alloc(*const ast.Expr, 1);
        call_args[0] = spread_arg;
        const super_expr = try p.node(sp, .{ .super_call = call_args }, 0);
        const body = try p.arena.alloc(ast.Stmt, 1);
        body[0] = .{ .span = sp, .data = .{ .expression = super_expr } };

        f.* = .{
            .span = sp,
            .id = fn_id,
            .kind = .expression,
            .is_class_constructor = true,
            .has_super_ctor = true,
            .has_home_object = true,
            .name = null,
            .inferred_name = if (name_decl) |nd| nd.name else "",
            .params = params,
            .body = body,
        };
        return f;
    }
};

fn span(first: Token, last: Token) ast.Span {
    return .{ .start = first.start, .end = last.end };
}

fn paramLength(params: []const ast.Param) u16 {
    for (params, 0..) |param, i| {
        if (param.default != null or param.is_rest) return @intCast(i);
    }
    return @intCast(params.len);
}

fn inferExprName(e: *const ast.Expr, name: []const u8) void {
    switch (e.data) {
        .function => |f| if (f.name == null and f.inferred_name.len == 0) {
            @constCast(f).inferred_name = name;
        },
        .class => |c| if (c.name == null and c.constructor.inferred_name.len == 0) {
            @constCast(c.constructor).inferred_name = name;
        },
        else => {},
    }
}

fn hexAt(s: []const u8, i: usize) ?u16 {
    if (i >= s.len) return null;
    return std.fmt.charToDigit(s[i], 16) catch null;
}

fn appendCodePoint(out: *std.ArrayList(u16), cp: u21) void {
    if (cp < 0x10000) return out.appendAssumeCapacity(@intCast(cp));
    const c = cp - 0x10000;
    out.appendAssumeCapacity(@intCast(0xD800 + (c >> 10)));
    out.appendAssumeCapacity(@intCast(0xDC00 + (c & 0x3FF)));
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn parseForTest(arena: Allocator, source: []const u8, limits: Limits) !ast.Script {
    var d: Diagnostic = .{};
    return parse(arena, source, limits, &d);
}

fn expectString(source: []const u8, expected: []const u16) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const script = try parseForTest(arena.allocator(), source, .{});
    try testing.expectEqualSlices(u16, expected, script.statements[0].data.expression.data.string);
}

test "string literals decode to UTF-16, including surrogates" {
    try expectString("'abc';", &.{ 'a', 'b', 'c' });
    try expectString("'\\uD800';", &.{0xD800}); // lone high surrogate: length 1
    try expectString("'\\uDE00\\uD83D';", &.{ 0xDE00, 0xD83D }); // reversed halves stay unpaired
    try expectString("'\\uD83D\\uDE00';", &.{ 0xD83D, 0xDE00 });
    try expectString("'\\u{1F600}';", &.{ 0xD83D, 0xDE00 });
    try expectString("'😀';", &.{ 0xD83D, 0xDE00 });
    try expectString("'\\u{10FFFF}';", &.{ 0xDBFF, 0xDFFF });
    try expectString("'\\u{0000000041}';", &.{'A'});
    try expectString("'é';", &.{0xE9});
    try expectString("'\\x41\\0\\q\\'\\\\';", &.{ 'A', 0, 'q', '\'', '\\' });
    try expectString("'a\\\nb\\\r\nc';", &.{ 'a', 'b', 'c' });
    try expectString("'a\\\u{2028}b';", &.{ 'a', 'b' }); // escaped LS is a line continuation
    try expectString("'a\u{2028}b';", &.{ 'a', 0x2028, 'b' }); // raw LS is allowed in strings
    try expectString("'\\é';", &.{0xE9});
}

test "invalid UTF-8 inside a string literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    for ([_][]const u8{ "'\xFF';", "'\xC0\xAF';", "'\xED\xA0\x80';", "'\xE2\x82';" }) |src| {
        try testing.expectError(error.Unsupported, parse(arena.allocator(), src, .{}, &d));
        try testing.expectEqual(Feature.invalid_utf8, d.detail.unsupported);
    }
}

test "limit: source size" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.LimitExceeded, parseForTest(arena.allocator(), "1+2;", .{ .max_source_bytes = 3 }));
    _ = try parseForTest(arena.allocator(), "1+2;", .{ .max_source_bytes = 4 });
}

/// `((…(1)…));` with n parentheses, `1+1+…+1;` with n additions, or
/// `let x; x = x = … = 1;` with n assignments.
fn nestedSource(a: Allocator, n: usize, comptime kind: enum { parens, chain, assignments }) ![]u8 {
    var s: std.ArrayList(u8) = .empty;
    switch (kind) {
        .parens => {
            try s.appendNTimes(a, '(', n);
            try s.append(a, '1');
            try s.appendNTimes(a, ')', n);
        },
        .chain => {
            try s.append(a, '1');
            for (0..n) |_| try s.appendSlice(a, "+1");
        },
        .assignments => {
            try s.appendSlice(a, "let x; ");
            for (0..n) |_| try s.appendSlice(a, "x = ");
            try s.append(a, '1');
        },
    }
    try s.append(a, ';');
    return s.items;
}

test "limit: nesting via parentheses and via operator chains" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const limits: Limits = .{ .max_nesting_depth = 50 };
    var d: Diagnostic = .{};

    // Each parenthesis level costs two recursion levels (`expression` → `binary`).
    try testing.expectError(error.LimitExceeded, parse(a, try nestedSource(a, 30, .parens), limits, &d));
    try testing.expectEqual(@import("../limits.zig").Limit.nesting_depth, d.detail.limit_exceeded);
    // A left-associative chain is parsed by a loop, but builds a 60-deep tree.
    try testing.expectError(error.LimitExceeded, parse(a, try nestedSource(a, 60, .chain), limits, &d));
    // Right-associative assignment chains recurse once per `=`.
    try testing.expectError(error.LimitExceeded, parse(a, try nestedSource(a, 60, .assignments), limits, &d));

    // Just under the limit is fine.
    _ = try parse(a, try nestedSource(a, 23, .parens), limits, &d);
    _ = try parse(a, try nestedSource(a, 48, .chain), limits, &d);
}
