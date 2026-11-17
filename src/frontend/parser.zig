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

pub const Error = error{ SyntaxError, Unsupported, LimitExceeded, OutOfMemory };

/// Parses a whole script. `arena` must be an arena-style allocator: nodes are never
/// freed individually; the caller frees everything at once, also after an error.
/// On any error other than OutOfMemory, `diag` describes the problem.
/// The returned AST borrows names from `source`.
pub fn parse(arena: Allocator, source: []const u8, limits: Limits, diag: *Diagnostic) Error!ast.Script {
    if (source.len > limits.max_source_bytes) {
        diag.* = .{ .detail = .{ .limit_exceeded = .source_bytes } };
        return error.LimitExceeded;
    }
    var p: Parser = .{ .lexer = .init(source, diag), .arena = arena, .limits = limits, .tok = undefined };
    p.tok = try p.lexer.next();

    var statements: std.ArrayList(ast.Stmt) = .empty;
    while (p.tok.tag != .eof) try statements.append(arena, try p.statementListItem(.body));
    return .{ .statements = statements.items, .ref_count = p.ref_count, .binding_count = p.binding_count, .function_count = p.function_count };
}

const unary_bp = 8;

const Infix = struct { op: ast.BinaryOp, bp: u8, right_assoc: bool = false };

/// Binding powers: a higher number binds tighter.
fn infix(tag: Tag) ?Infix {
    return switch (tag) {
        .pipe_pipe => .{ .op = .logical_or, .bp = 1 },
        .amp_amp => .{ .op = .logical_and, .bp = 2 },
        .eq3 => .{ .op = .strict_eq, .bp = 3 },
        .neq3 => .{ .op = .strict_ne, .bp = 3 },
        .lt => .{ .op = .lt, .bp = 4 },
        .le => .{ .op = .le, .bp = 4 },
        .gt => .{ .op = .gt, .bp = 4 },
        .ge => .{ .op = .ge, .bp = 4 },
        .plus => .{ .op = .add, .bp = 5 },
        .minus => .{ .op = .sub, .bp = 5 },
        .star => .{ .op = .mul, .bp = 6 },
        .slash => .{ .op = .div, .bp = 6 },
        .percent => .{ .op = .mod, .bp = 6 },
        .star_star => .{ .op = .pow, .bp = 7, .right_assoc = true },
        else => null,
    };
}

/// `=` gives null (plain assignment); compound operators give their binary op.
fn assignOp(tag: Tag) ?(?ast.BinaryOp) {
    return switch (tag) {
        .eq => @as(?ast.BinaryOp, null),
        .plus_eq => .add,
        .minus_eq => .sub,
        .star_eq => .mul,
        .slash_eq => .div,
        .percent_eq => .mod,
        .star_star_eq => .pow,
        else => null,
    };
}

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
    /// Number of enclosing functions; `return` is legal only when > 0.
    function_depth: u32 = 0,
    /// Inside a `for (…;` head: `in` is not an operator there (`for (x in o)` is for-in).
    /// Brackets, parentheses and literals turn it back on (`nested`), as in the grammar.
    no_in: bool = false,
    ref_count: u32 = 0,
    binding_count: u32 = 0,
    function_count: u32 = 1, // function 0 is the script

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
            const f = try p.function(.declaration);
            return .{ .span = .{ .start = t.start, .end = f.span.end }, .data = .{ .function = f } };
        }
        if (p.tok.tag == .kw_const) return p.declarationStatement(.@"const");
        if (p.isText(p.tok, "let") and try p.letStartsDeclaration()) return p.declarationStatement(.let);
        return p.statement();
    }

    /// `let` begins a declaration when followed by a binding name, even on the next
    /// line (`let\nx = 1` declares x). Followed by anything else, `let` is an ordinary
    /// identifier in sloppy JS (`let;`, `let = 1`) or destructuring (`let [a]`).
    /// `let in x` / `let instanceof x` are expressions using a variable named `let`.
    fn letStartsDeclaration(p: *Parser) Error!bool {
        const next = try p.peek();
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
        if (p.isText(t, "return")) return p.returnStatement();
        if (p.isText(t, "throw")) return p.throwStatement();
        if (p.isText(t, "try")) return p.tryStatement();
        if (p.isText(t, "do")) return p.doWhileStatement();
        if (p.isText(t, "switch")) return p.switchStatement();
        if (p.isText(t, "let")) {
            const next = try p.peek();
            // `if (c) let x` is an error, but `if (c) let\nx` may be ASI + two statements.
            if (next.tag == .identifier and !next.newline_before and !p.isText(next, "in") and !p.isText(next, "instanceof"))
                return p.fail(.{ .syntax_error = "lexical declaration cannot appear in a single-statement context" }, t);
            return p.fail(.{ .unsupported = .syntax }, t);
        }
        const e = try p.expression();
        // `foo: …` is a label; any other `:` after an expression is unsupported syntax.
        if (p.tok.tag == .colon and e.data == .identifier) return p.fail(.{ .unsupported = .labels }, p.tok);
        const end = p.tok;
        try p.endStatement();
        return .{ .span = .{ .start = e.span.start, .end = end.end }, .data = .{ .expression = e } };
    }

    fn declarationStatement(p: *Parser, kind: ast.DeclKind) Error!ast.Stmt {
        const start = p.tok.start;
        const decl = try p.declaration(kind, false);
        const end = p.tok;
        try p.endStatement();
        return .{ .span = .{ .start = start, .end = end.end }, .data = .{ .declaration = decl } };
    }

    /// `let|const name [= init] (, name [= init])*` without the terminator.
    fn declaration(p: *Parser, kind: ast.DeclKind, allow_for_of: bool) Error!ast.Declaration {
        try p.advance(); // `let` / `const`
        var list: std.ArrayList(ast.Declarator) = .empty;
        while (true) {
            const name_tok = p.tok;
            const name = name_tok.text(p.source());
            if (name_tok.tag != .identifier and !token.isKeyword(name_tok.tag))
                return p.fail(.{ .unsupported = .syntax }, name_tok); // destructuring, …
            if (token.isKeyword(name_tok.tag) or token.reserved_identifiers.has(name) or std.mem.eql(u8, name, "let"))
                return p.fail(.{ .syntax_error = "reserved word cannot be a variable name" }, name_tok);
            try p.advance();
            if (p.isText(p.tok, "in")) return p.fail(.{ .unsupported = .syntax }, p.tok);
            if (p.isText(p.tok, "of")) {
                if (!allow_for_of or list.items.len > 0) return p.fail(.{ .syntax_error = "invalid for-of declaration" }, p.tok);
                try list.append(p.arena, .{ .name = name, .span = span(name_tok, name_tok), .binding = p.binding_count, .init = null });
                p.binding_count += 1;
                return .{ .kind = kind, .declarators = list.items };
            }
            var init: ?*const ast.Expr = null;
            if (p.tok.tag == .eq) {
                try p.advance();
                init = try p.expression();
            } else if (kind == .@"const") {
                return p.fail(.{ .syntax_error = "missing initializer in const declaration" }, name_tok);
            }
            try list.append(p.arena, .{ .name = name, .span = span(name_tok, name_tok), .binding = p.binding_count, .init = init });
            p.binding_count += 1;
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
        if (p.tok.tag != .l_paren) {
            // `for await (…)` is valid JS; `for x` is not, but we needn't be precise.
            return p.fail(.{ .unsupported = .syntax }, p.tok);
        }
        try p.advance();

        var init: ?ast.ForInit = null;
        p.no_in = true;
        if (p.tok.tag == .kw_const) {
            init = .{ .declaration = try p.declaration(.@"const", true) };
        } else if (p.isText(p.tok, "let") and try p.letStartsDeclaration()) {
            init = .{ .declaration = try p.declaration(.let, true) };
        } else if (p.tok.tag != .semicolon) {
            init = .{ .expression = try p.expression() };
        }
        p.no_in = false;
        if (p.isText(p.tok, "in")) return p.fail(.{ .unsupported = .syntax }, p.tok);
        if (p.isText(p.tok, "of")) {
            const target: ast.ForOfTarget = switch (init orelse return p.fail(.{ .syntax_error = "missing left-hand side in for-of" }, p.tok)) {
                .declaration => |decl| blk: {
                    if (decl.declarators.len != 1 or decl.declarators[0].init != null)
                        return p.fail(.{ .syntax_error = "for-of loop variable declaration may not have an initializer" }, p.tok);
                    break :blk .{ .declaration = .{ .kind = decl.kind, .declarator = decl.declarators[0] } };
                },
                .expression => |e| blk: {
                    if (e.data != .identifier) return p.failAt(.{ .unsupported = .syntax }, e.span.start, e.span.end);
                    break :blk .{ .target = try p.assignTarget(e, "invalid left-hand side in for-of") };
                },
            };
            try p.advance();
            const iterable = try p.expression();
            try p.expectAfterExpression(.r_paren);
            const body = try p.loopBody();
            return .{ .span = .{ .start = start, .end = body.span.end }, .data = .{ .for_of = .{ .target = target, .iterable = iterable, .body = body } } };
        }
        try p.expectAfterExpression(.semicolon);

        const cond = if (p.tok.tag == .semicolon) null else try p.expression();
        try p.expectAfterExpression(.semicolon);
        const update = if (p.tok.tag == .r_paren) null else try p.expression();
        try p.expectAfterExpression(.r_paren);

        const body = try p.loopBody();
        return .{ .span = .{ .start = start, .end = body.span.end }, .data = .{ .@"for" = .{ .init = init, .cond = cond, .update = update, .body = body } } };
    }

    fn loopBody(p: *Parser) Error!*const ast.Stmt {
        p.loop_depth += 1;
        defer p.loop_depth -= 1;
        return p.boxed(try p.statement());
    }

    /// `break;` / `continue;`. Labels and ASI are classified carefully:
    ///   `break foo;`   label (same line): Unsupported(labels), even outside a loop,
    ///                  because `foo: { break foo; }` is valid JS
    ///   `break\nfoo;`  ASI makes this `break; foo;`: Unsupported(asi) inside a loop,
    ///                  SyntaxError outside one (an unlabeled break needs a loop)
    fn jumpStatement(p: *Parser) Error!ast.Stmt {
        const t = p.tok;
        try p.advance();
        if (p.tok.tag == .identifier and !p.tok.newline_before) return p.fail(.{ .unsupported = .labels }, p.tok);
        if (t.tag == .kw_break) {
            if (p.loop_depth == 0 and p.switch_depth == 0)
                return p.fail(.{ .syntax_error = "'break' outside a loop or switch" }, t);
        } else if (p.loop_depth == 0) {
            return p.fail(.{ .syntax_error = "'continue' outside a loop" }, t);
        }
        const end = p.tok;
        try p.endStatement();
        return .{ .span = span(t, end), .data = if (t.tag == .kw_break) .@"break" else .@"continue" };
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
                .r_paren, .r_bracket, .comma, .colon, .eq, .star, .star_star, .percent, .eq3, .neq3, .eq2, .neq2, .lt, .le, .gt, .ge, .amp_amp, .pipe_pipe, .question2, .question, .question_dot, .arrow, .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq, .star_star_eq, .shl_eq, .shr_eq, .ushr_eq, .amp_eq, .pipe_eq, .caret_eq, .amp_amp_eq, .pipe_pipe_eq, .question2_eq => true,
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

    /// `try { ... } catch [(e)] { ... }`. `finally` is Unsupported.
    fn tryStatement(p: *Parser) Error!ast.Stmt {
        const start = p.tok.start;
        try p.advance(); // `try`
        if (p.tok.tag != .l_brace) return p.fail(.{ .syntax_error = "expected '{' after try" }, p.tok);
        const try_blk = try p.block();
        if (p.isText(p.tok, "finally")) return p.fail(.{ .unsupported = .syntax }, p.tok);
        if (!p.isText(p.tok, "catch")) return p.fail(.{ .syntax_error = "missing catch or finally after try" }, p.tok);
        try p.advance(); // `catch`
        var param: ?ast.Declarator = null;
        if (p.tok.tag == .l_paren) {
            try p.advance();
            if (p.tok.tag == .l_brace or p.tok.tag == .l_bracket) return p.fail(.{ .unsupported = .syntax }, p.tok);
            param = try p.bindingName();
            if (p.tok.tag != .r_paren) return p.fail(.{ .syntax_error = "expected ')' after catch parameter" }, p.tok);
            try p.advance();
        }
        if (p.tok.tag != .l_brace) return p.fail(.{ .syntax_error = "expected '{' after catch" }, p.tok);
        const catch_blk = try p.block();
        if (p.isText(p.tok, "finally")) return p.fail(.{ .unsupported = .syntax }, p.tok);
        return .{
            .span = .{ .start = start, .end = catch_blk.span.end },
            .data = .{ .@"try" = .{ .body = try_blk.data.block, .catch_param = param, .catch_body = catch_blk.data.block } },
        };
    }

    /// `function [name](a, b, …) { body }`, starting at `function`.
    fn function(p: *Parser, kind: @FieldType(ast.Function, "kind")) Error!*const ast.Function {
        try p.enter();
        defer p.depth -= 1;
        const start = p.tok.start;
        try p.advance(); // `function`
        if (p.tok.tag == .star) return p.fail(.{ .unsupported = .syntax }, p.tok); // generator

        var name: ?ast.Declarator = null;
        if (p.tok.tag != .l_paren) {
            name = try p.bindingName();
        } else if (kind == .declaration) {
            return p.fail(.{ .syntax_error = "function declaration needs a name" }, p.tok);
        }
        return p.functionRest(start, kind, name);
    }

    /// From the parameter list on: shared by `function` and object-literal methods
    /// (`{ f(a) { … } }`, an anonymous function expression whose name is not bound).
    fn functionRest(p: *Parser, start: u32, kind: @FieldType(ast.Function, "kind"), name: ?ast.Declarator) Error!*const ast.Function {
        const id = p.function_count;
        p.function_count += 1;
        const params = try p.parseParams();

        if (p.tok.tag != .l_brace) return p.fail(.{ .syntax_error = "expected '{'" }, p.tok);
        const outer_loops = p.loop_depth;
        const outer_switches = p.switch_depth;
        p.loop_depth = 0;
        p.switch_depth = 0;
        p.function_depth += 1;
        defer {
            p.loop_depth = outer_loops;
            p.switch_depth = outer_switches;
            p.function_depth -= 1;
        }
        const parsed_body = try p.parseFunctionBody();

        const f = try p.arena.create(ast.Function);
        f.* = .{ .span = .{ .start = start, .end = parsed_body.end }, .id = id, .kind = kind, .name = name, .params = params, .body = parsed_body.body };
        return f;
    }

    fn parseParams(p: *Parser) Error![]const ast.Declarator {
        if (p.tok.tag != .l_paren) return p.fail(.{ .syntax_error = "expected '('" }, p.tok);
        try p.advance();
        var params: std.ArrayList(ast.Declarator) = .empty;
        while (p.tok.tag != .r_paren) {
            // Defaults, rest parameters and destructuring are valid JS outside ZQJS.
            if (p.tok.tag != .identifier and !token.isKeyword(p.tok.tag)) return p.fail(.{ .unsupported = .syntax }, p.tok);
            try params.append(p.arena, try p.bindingName());
            if (p.tok.tag == .eq) return p.fail(.{ .unsupported = .syntax }, p.tok);
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
    /// sloppy-mode name ZQJS doesn't support; `arguments` would shadow the arguments object.
    fn bindingName(p: *Parser) Error!ast.Declarator {
        const t = p.tok;
        const name = t.text(p.source());
        if (t.tag != .identifier and !token.isKeyword(t.tag)) return p.fail(.{ .unsupported = .syntax }, t);
        if (token.isKeyword(t.tag) or token.reserved_identifiers.has(name))
            return p.fail(.{ .syntax_error = "reserved word cannot be a binding name" }, t);
        if (std.mem.eql(u8, name, "let")) return p.fail(.{ .unsupported = .syntax }, t);
        if (std.mem.eql(u8, name, "arguments")) return p.fail(.{ .unsupported = .arguments }, t);
        try p.advance();
        const d: ast.Declarator = .{ .name = name, .span = span(t, t), .binding = p.binding_count, .init = null };
        p.binding_count += 1;
        return d;
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

    /// Expression := Assignment. Assignment is right-associative and binds loosest.
    fn expression(p: *Parser) Error!*const ast.Expr {
        try p.enter();
        defer p.depth -= 1;
        if (p.isArrowStart()) return p.arrowFunction();
        const paren_start = p.tok.tag == .l_paren;
        const lhs = try p.conditional();
        // `(a = 1) =>`, `([a]) =>`: valid JS parameter lists that isArrowStart doesn't accept.
        if (paren_start and p.tok.tag == .arrow) return p.fail(.{ .unsupported = .syntax }, p.tok);
        const op = assignOp(p.tok.tag) orelse return lhs;
        // Parentheses are transparent, so `(x) = 1` arrives here as a plain identifier, as in JS.
        const target = try p.assignTarget(lhs, "invalid assignment target");
        try p.advance();
        const value = try p.expression();
        return p.node(
            .{ .start = lhs.span.start, .end = value.span.end },
            .{ .assign = .{ .op = op, .target = target, .value = value } },
            @max(lhs.depth, value.depth),
        );
    }

    fn isArrowStart(p: *Parser) bool {
        if (p.tok.tag == .identifier) {
            var look = p.lexer;
            const next_tok = look.next() catch return false;
            return next_tok.tag == .arrow;
        }
        if (p.tok.tag == .l_paren) {
            // Only `(ident, ident,)` can be supported parameters, so stop at the first other
            // token: scanning to the matching `)` made nested parentheses quadratic.
            var look = p.lexer;
            while (true) {
                const t = look.next() catch return false;
                switch (t.tag) {
                    .identifier, .comma => {},
                    .r_paren => break,
                    else => return false,
                }
            }
            const after = look.next() catch return false;
            return after.tag == .arrow;
        }
        return false;
    }

    fn arrowFunction(p: *Parser) Error!*const ast.Expr {
        try p.enter();
        defer p.depth -= 1;
        const start = p.tok.start;
        const id = p.function_count;
        p.function_count += 1;

        var params: []const ast.Declarator = &.{};
        if (p.tok.tag == .l_paren) {
            params = try p.parseParams();
        } else {
            const single = try p.bindingName();
            const buf = try p.arena.alloc(ast.Declarator, 1);
            buf[0] = single;
            params = buf;
        }

        if (p.tok.tag != .arrow) return p.fail(.{ .syntax_error = "expected '=>'" }, p.tok);
        if (p.tok.newline_before) return p.fail(.{ .syntax_error = "line terminator before '=>'" }, p.tok);
        try p.advance(); // `=>`

        const outer_loops = p.loop_depth;
        const outer_switches = p.switch_depth;
        p.loop_depth = 0;
        p.switch_depth = 0;
        p.function_depth += 1;
        defer {
            p.loop_depth = outer_loops;
            p.switch_depth = outer_switches;
            p.function_depth -= 1;
        }

        var body: []const ast.Stmt = undefined;
        var end: u32 = undefined;
        if (p.tok.tag == .l_brace) {
            const parsed_body = try p.parseFunctionBody();
            body = parsed_body.body;
            end = parsed_body.end;
        } else {
            const expr = try p.expression();
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
            .name = null,
            .params = params,
            .body = body,
        };
        return p.node(f.span, .{ .function = f }, 0);
    }

    /// ConditionalExpression := LogicalORExpression (`?` AssignmentExpression `:` AssignmentExpression)?
    fn conditional(p: *Parser) Error!*const ast.Expr {
        const cond = try p.binary(0);
        if (p.tok.tag != .question) return cond;
        try p.enter();
        defer p.depth -= 1;
        try p.advance();
        // `then` allows `in` even inside `for (...; ...)` (`no_in = false`); `else` keeps the outer `no_in`.
        const then_expr = try p.nested();
        if (p.tok.tag != .colon) return p.fail(.{ .syntax_error = "expected ':'" }, p.tok);
        try p.advance();
        const else_expr = try p.expression();
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

    fn binary(p: *Parser, min_bp: u8) Error!*const ast.Expr {
        try p.enter();
        defer p.depth -= 1;

        var lhs = try p.prefix();
        while (true) {
            if (p.tok.tag == .eq2 or p.tok.tag == .neq2) return p.fail(.{ .unsupported = .loose_equality }, p.tok);
            const info: Infix = if (!p.no_in and p.isText(p.tok, "in")) .{ .op = .in, .bp = 4 } else infix(p.tok.tag) orelse break;
            if (info.bp < min_bp) break;
            try p.advance();
            const rhs = try p.binary(if (info.right_assoc) info.bp else info.bp + 1);
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
            .minus, .plus, .bang => {
                try p.advance();
                const operand = try p.binary(unary_bp);
                // JS forbids `-a ** b`: it is ambiguous whether `-` applies before or after `**`.
                // (`++a ** b` is fine: update expressions are not unary operators here.)
                if (p.tok.tag == .star_star)
                    return p.fail(.{ .syntax_error = "unary operator before '**' needs parentheses" }, t);
                const op: ast.UnaryOp = switch (t.tag) {
                    .minus => .neg,
                    .plus => .plus,
                    else => .not,
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
                // only member deletion is part of ZQJS.
                if (operand.data != .member) return p.fail(.{ .unsupported = .syntax }, t);
                return p.node(.{ .start = t.start, .end = operand.span.end }, .{ .delete = operand.data.member }, operand.depth);
            } else if (p.isText(t, "typeof")) {
                try p.advance();
                const operand = try p.binary(unary_bp);
                if (p.tok.tag == .star_star)
                    return p.fail(.{ .syntax_error = "unary operator before '**' needs parentheses" }, t);
                return p.node(.{ .start = t.start, .end = operand.span.end }, .{ .unary = .{ .op = .typeof, .operand = operand } }, operand.depth);
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

    fn memberStep(p: *Parser, callee: *const ast.Expr) Error!?*const ast.Expr {
        return switch (p.tok.tag) {
            .dot => blk: {
                try p.advance();
                const name = p.tok;
                // Any identifier or keyword names a property: `o.if`, `o.this`. A literal,
                // `=` or a closing token can't follow `.` in any JS; others (`o.#x`) might.
                if (name.tag != .identifier and !token.isKeyword(name.tag)) return switch (name.tag) {
                    .eof, .semicolon, .comma, .eq, .r_paren, .r_bracket, .r_brace, .number, .string => p.fail(.{ .syntax_error = "expected a property name after '.'" }, name),
                    else => p.fail(.{ .unsupported = .syntax }, name),
                };
                try p.advance();
                break :blk try p.node(.{ .start = callee.span.start, .end = name.end }, .{ .member = .{ .object = callee, .key = .{ .name = name.text(p.source()) } } }, callee.depth);
            },
            .l_bracket => blk: {
                try p.advance();
                const k = try p.nested();
                const close = p.tok;
                try p.expectAfterExpression(.r_bracket);
                break :blk try p.node(.{ .start = callee.span.start, .end = close.end }, .{ .member = .{ .object = callee, .key = .{ .computed = k } } }, @max(callee.depth, k.depth));
            },
            .question_dot => p.fail(.{ .unsupported = .syntax }, p.tok), // optional chaining
            else => null,
        };
    }

    fn members(p: *Parser, callee_in: *const ast.Expr) Error!*const ast.Expr {
        var callee = callee_in;
        while (try p.memberStep(callee)) |next| callee = next;
        return callee;
    }

    /// `callee(args)`, `object.name`, `object[key]`, chained. Unlike `++`, these may
    /// continue on the next line: `x\n(2)` calls x, `x\n[0]` indexes it.
    fn calls(p: *Parser, callee_in: *const ast.Expr) Error!*const ast.Expr {
        var callee = callee_in;
        while (true) {
            if (p.tok.tag == .l_paren) {
                callee = try p.callArgs(callee);
            } else if (try p.memberStep(callee)) |next| {
                callee = next;
            } else if (p.tok.tag == .template_no_sub or p.tok.tag == .template_head) {
                return p.fail(.{ .unsupported = .syntax }, p.tok); // tagged template
            } else return callee;
        }
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
        return p.node(.{ .start = start, .end = target.span.end }, .{ .new_call = .{ .callee = target, .args = &.{} } }, target.depth);
    }

    fn callArgs(p: *Parser, callee: *const ast.Expr) Error!*const ast.Expr {
        {
            try p.advance();
            var args: std.ArrayList(*const ast.Expr) = .empty;
            var depth = callee.depth;
            while (p.tok.tag != .r_paren) {
                if (p.tok.tag == .ellipsis) return p.fail(.{ .unsupported = .syntax }, p.tok); // spread
                const arg = try p.nested();
                try args.append(p.arena, arg);
                depth = @max(depth, arg.depth);
                if (p.tok.tag != .comma) break;
                try p.advance(); // a trailing comma is allowed: `f(1,)`
            }
            const close = p.tok;
            try p.expectAfterExpression(.r_paren);
            return p.node(
                .{ .start = callee.span.start, .end = close.end },
                .{ .call = .{ .callee = callee, .args = args.items } },
                depth,
            );
        }
    }

    /// `[a, b, …]`. Holes (`[1,,2]`) are Unsupported: arrays are dense (D13).
    fn arrayLiteral(p: *Parser) Error!*const ast.Expr {
        const open = p.tok;
        try p.advance();
        var items: std.ArrayList(*const ast.Expr) = .empty;
        var depth: u16 = 0;
        while (p.tok.tag != .r_bracket) {
            if (p.tok.tag == .comma) return p.fail(.{ .unsupported = .sparse_array }, p.tok);
            if (p.tok.tag == .ellipsis) return p.fail(.{ .unsupported = .syntax }, p.tok); // spread
            if (p.tok.tag == .eof) return p.fail(.{ .syntax_error = "unterminated array literal" }, open);
            const e = try p.nested();
            try items.append(p.arena, e);
            depth = @max(depth, e.depth);
            if (p.tok.tag != .comma) break;
            try p.advance(); // a trailing comma adds no element
        }
        const close = p.tok;
        try p.expectAfterExpression(.r_bracket);
        return p.node(span(open, close), .{ .array = items.items }, depth);
    }

    /// `{ key: value, [expr]: value, name, method() {…}, … }`.
    fn objectLiteral(p: *Parser) Error!*const ast.Expr {
        const open = p.tok;
        try p.advance();
        var props: std.ArrayList(ast.PropertyDef) = .empty;
        var depth: u16 = 0;
        while (p.tok.tag != .r_brace) {
            const t = p.tok;
            const k: ast.PropertyKey = switch (t.tag) {
                .l_bracket => blk: {
                    try p.advance();
                    const e = try p.nested();
                    try p.expectAfterExpression(.r_bracket);
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
                .eof => return p.fail(.{ .syntax_error = "unterminated object literal" }, open),
                else => blk: {
                    if (t.tag != .identifier and !token.isKeyword(t.tag)) return p.fail(.{ .unsupported = .syntax }, t); // `...`, `*`, …
                    const name = t.text(p.source());
                    // `get x() {}`, `set x(v) {}`, `async f() {}`: accessors and async methods.
                    if (std.mem.eql(u8, name, "get") or std.mem.eql(u8, name, "set") or std.mem.eql(u8, name, "async")) {
                        const next = try p.peek();
                        switch (next.tag) {
                            .colon, .l_paren, .comma, .r_brace => {},
                            else => return p.fail(.{ .unsupported = .syntax }, t),
                        }
                    }
                    try p.advance();
                    break :blk .{ .name = name };
                },
            };
            const value: *const ast.Expr = switch (p.tok.tag) {
                .colon => blk: {
                    if (isProtoKey(k)) return p.fail(.{ .unsupported = .builtin }, t); // sets the prototype
                    try p.advance();
                    break :blk try p.nested();
                },
                .l_paren => blk: {
                    const f = try p.functionRest(t.start, .expression, null);
                    break :blk try p.node(f.span, .{ .function = f }, 0);
                },
                .comma, .r_brace => blk: {
                    // Shorthand `{ x }` is a reference to the variable x.
                    if (k != .name or t.tag != .identifier) return p.fail(.{ .syntax_error = "unexpected token in object literal" }, p.tok);
                    if (token.reserved_identifiers.has(k.name)) return p.fail(.{ .syntax_error = "reserved word as shorthand property" }, t);
                    if (std.mem.eql(u8, k.name, "let")) return p.fail(.{ .unsupported = .syntax }, t);
                    if (std.mem.eql(u8, k.name, "arguments")) return p.fail(.{ .unsupported = .arguments }, t);
                    const id = p.ref_count;
                    p.ref_count += 1;
                    break :blk try p.node(span(t, t), .{ .identifier = .{ .name = k.name, .span = span(t, t), .id = id } }, 0);
                },
                .eq => return p.fail(.{ .unsupported = .syntax }, p.tok), // `{ a = 1 }`: destructuring
                .number, .string, .identifier => return p.fail(.{ .syntax_error = "unexpected token in object literal" }, p.tok),
                else => return p.fail(.{ .unsupported = .syntax }, p.tok),
            };
            try props.append(p.arena, .{ .key = k, .value = value, .span = .{ .start = t.start, .end = value.span.end } });
            depth = @max(depth, value.depth);
            if (k == .computed) depth = @max(depth, k.computed.depth);
            if (p.tok.tag != .comma) break;
            try p.advance(); // a trailing comma is allowed
        }
        const close = p.tok;
        try p.expectAfterExpression(.r_brace);
        return p.node(span(open, close), .{ .object = props.items }, depth);
    }

    /// The literal key `__proto__:` (not computed, not shorthand) sets the prototype.
    fn isProtoKey(k: ast.PropertyKey) bool {
        return switch (k) {
            .name => |n| std.mem.eql(u8, n, "__proto__"),
            .string => |u| std.mem.eql(u16, u, std.unicode.utf8ToUtf16LeStringLiteral("__proto__")),
            else => false,
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
                    const f = try p.function(.expression);
                    return p.node(f.span, .{ .function = f }, 0);
                }
                if (std.mem.eql(u8, name, "new")) {
                    return p.newExpr();
                }
                // Inside a function, `arguments` is the arguments object.
                if (std.mem.eql(u8, name, "arguments")) return p.fail(.{ .unsupported = .arguments }, t);
                // `this`, `new`, `typeof`, `function`, … start constructs ZQJS lacks;
                // `let` as a variable name is legal sloppy JS we choose not to support.
                if (token.reserved_identifiers.has(name) or std.mem.eql(u8, name, "let"))
                    return p.fail(.{ .unsupported = .syntax }, t);
                try p.advance();
                const id = p.ref_count;
                p.ref_count += 1;
                return p.node(s, .{ .identifier = .{ .name = name, .span = s, .id = id } }, 0);
            },
            .l_paren => {
                try p.advance();
                // `()` is only valid as an arrow-function parameter list.
                if (p.tok.tag == .r_paren) return p.fail(.{ .syntax_error = "unexpected token ')'" }, p.tok);
                if (p.tok.tag == .ellipsis) return p.fail(.{ .unsupported = .syntax }, p.tok); // `(...a) =>`
                const inner = try p.nested();
                try p.expectAfterExpression(.r_paren);
                return inner;
            },
            // Tokens that cannot begin an expression in any JavaScript.
            .eof, .semicolon, .r_paren, .r_bracket, .r_brace, .comma, .star, .star_star, .percent, .eq3, .neq3, .eq2, .neq2, .lt, .le, .gt, .ge, .amp_amp, .pipe_pipe, .question2, .question, .question_dot, .colon, .eq, .arrow => return p.fail(.{ .syntax_error = "unexpected token" }, t),
            // `[`, `{`, `/` (regex), `~`, `...`, keywords, … may start valid JS.
            else => return p.fail(.{ .unsupported = .syntax }, t),
        }
    }

    /// `t` follows a complete expression but is not what the grammar expects.
    /// It is a SyntaxError only if no JavaScript operator or construct can follow an
    /// expression with this token (and, at statement level, ASI does not apply).
    fn unexpectedAfterExpression(p: *Parser, t: Token) Error {
        const certain = switch (t.tag) {
            .number, .string, .kw_true, .kw_false, .kw_null, .r_paren, .r_bracket, .r_brace, .semicolon, .eof => true,
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

    /// Decodes a string literal token (quotes included) to UTF-16 code units
    /// (LANGUAGE.md §3). The lexer has already found the closing quote.
    fn decodeString(p: *Parser, t: Token) Error![]const u16 {
        const base = t.start + 1;
        return p.decodeEscapes(p.source()[base .. t.end - 1], base, false);
    }

    fn decodeEscapes(p: *Parser, s: []const u8, base: u32, is_template: bool) Error![]const u16 {
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
                    if (i < s.len and std.ascii.isDigit(s[i])) return p.failAt(.{ .unsupported = .legacy_octal }, esc_start, base + i + 1);
                    out.appendAssumeCapacity(0);
                },
                '1'...'9' => return p.failAt(.{ .unsupported = .legacy_octal }, esc_start, base + i),
                'x' => {
                    const hi = hexAt(s, i) orelse return p.failAt(.{ .syntax_error = "invalid hexadecimal escape" }, esc_start, base + i);
                    const lo = hexAt(s, i + 1) orelse return p.failAt(.{ .syntax_error = "invalid hexadecimal escape" }, esc_start, base + i);
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
                        const d = hexAt(s, i) orelse return p.failAt(.{ .syntax_error = "invalid Unicode escape" }, esc_start, base + i);
                        cp = @min(cp * 16 + d, 0x110000); // saturate: cp * 16 can't overflow
                    }
                    if (i >= s.len or n == 0) return p.failAt(.{ .syntax_error = "invalid Unicode escape" }, esc_start, base + i);
                    i += 1; // `}`
                    if (cp > 0x10FFFF) return p.failAt(.{ .syntax_error = "Unicode escape above U+10FFFF" }, esc_start, base + i);
                    appendCodePoint(&out, @intCast(cp));
                } else {
                    var unit: u16 = 0;
                    for (0..4) |k| {
                        const d = hexAt(s, i + k) orelse return p.failAt(.{ .syntax_error = "invalid Unicode escape" }, esc_start, base + i);
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
};

fn span(first: Token, last: Token) ast.Span {
    return .{ .start = first.start, .end = last.end };
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
