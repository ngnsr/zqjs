//! Pratt parser for the M1 grammar (LANGUAGE.md §4).
//!
//! Besides building the AST, the parser's main job is *classifying* failures
//! (LANGUAGE.md §1): `SyntaxError` only when no JavaScript parser could accept the
//! input, `Unsupported` for anything that might be valid JavaScript outside ZQJS.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Lexer = @import("lexer.zig").Lexer;
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
    while (p.tok.tag != .eof) try statements.append(arena, try p.statementListItem());
    return .{ .statements = statements.items, .ref_count = p.ref_count, .binding_count = p.binding_count };
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
    /// Number of enclosing loops; `break`/`continue` are legal only when > 0.
    loop_depth: u32 = 0,
    ref_count: u32 = 0,
    binding_count: u32 = 0,

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

    /// A statement where declarations are allowed: script top level and blocks.
    fn statementListItem(p: *Parser) Error!ast.Stmt {
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
        const decl = try p.declaration(kind);
        const end = p.tok;
        try p.endStatement();
        return .{ .span = .{ .start = start, .end = end.end }, .data = .{ .declaration = decl } };
    }

    /// `let|const name [= init] (, name [= init])*` without the terminator.
    fn declaration(p: *Parser, kind: ast.DeclKind) Error!ast.Declaration {
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
            // `for (const x of xs)` must not be reported as a missing initializer.
            if (p.isText(p.tok, "of") or p.isText(p.tok, "in")) return p.fail(.{ .unsupported = .syntax }, p.tok);
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
            try list.append(p.arena, try p.statementListItem());
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
        if (p.tok.tag == .kw_const) {
            init = .{ .declaration = try p.declaration(.@"const") };
        } else if (p.isText(p.tok, "let") and try p.letStartsDeclaration()) {
            init = .{ .declaration = try p.declaration(.let) };
        } else if (p.tok.tag != .semicolon) {
            init = .{ .expression = try p.expression() };
        }
        // `for (x of xs)` / `for (x in o)`
        if (p.isText(p.tok, "of") or p.isText(p.tok, "in")) return p.fail(.{ .unsupported = .syntax }, p.tok);
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
        if (p.loop_depth == 0) return p.fail(.{ .syntax_error = if (t.tag == .kw_break) "'break' outside a loop" else "'continue' outside a loop" }, t);
        const end = p.tok;
        try p.endStatement();
        return .{ .span = span(t, end), .data = if (t.tag == .kw_break) .@"break" else .@"continue" };
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
        const lhs = try p.binary(0);
        const op = assignOp(p.tok.tag) orelse return lhs;
        // Parentheses are transparent, so `(x) = 1` arrives here as a plain identifier, as in JS.
        if (lhs.data != .identifier) return p.invalidTarget(lhs, "invalid assignment target");
        try p.advance();
        const value = try p.expression();
        return p.node(
            .{ .start = lhs.span.start, .end = value.span.end },
            .{ .assign = .{ .op = op, .target = lhs.data.identifier, .value = value } },
            value.depth,
        );
    }

    fn binary(p: *Parser, min_bp: u8) Error!*const ast.Expr {
        try p.enter();
        defer p.depth -= 1;

        var lhs = try p.prefix();
        while (true) {
            if (p.tok.tag == .eq2 or p.tok.tag == .neq2) return p.fail(.{ .unsupported = .loose_equality }, p.tok);
            const info = infix(p.tok.tag) orelse break;
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
                    0,
                );
            },
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
            0,
        );
    }

    fn updateTarget(p: *Parser, operand: *const ast.Expr) Error!ast.Ref {
        if (operand.data != .identifier) return p.invalidTarget(operand, "invalid update target");
        return operand.data.identifier;
    }

    /// `f() = 1` and `f()++` are *runtime* ReferenceErrors in node (a web-compatibility
    /// rule), not SyntaxErrors, so for calls we must not claim a SyntaxError.
    fn invalidTarget(p: *Parser, e: *const ast.Expr, msg: []const u8) Error {
        if (e.data == .call) return p.failAt(.{ .unsupported = .syntax }, e.span.start, e.span.end);
        return p.failAt(.{ .syntax_error = msg }, e.span.start, e.span.end);
    }

    /// `callee(args)(args)…`. Unlike `++`, a call may continue on the next line:
    /// `x\n(2)` calls x.
    fn calls(p: *Parser, callee_in: *const ast.Expr) Error!*const ast.Expr {
        var callee = callee_in;
        while (p.tok.tag == .l_paren) {
            try p.advance();
            var args: std.ArrayList(*const ast.Expr) = .empty;
            var depth = callee.depth;
            while (p.tok.tag != .r_paren) {
                if (p.tok.tag == .ellipsis) return p.fail(.{ .unsupported = .syntax }, p.tok); // spread
                const arg = try p.expression();
                try args.append(p.arena, arg);
                depth = @max(depth, arg.depth);
                if (p.tok.tag != .comma) break;
                try p.advance(); // a trailing comma is allowed: `f(1,)`
            }
            const close = p.tok;
            try p.expectAfterExpression(.r_paren);
            callee = try p.node(
                .{ .start = callee.span.start, .end = close.end },
                .{ .call = .{ .callee = callee, .args = args.items } },
                depth,
            );
        }
        return callee;
    }

    fn primary(p: *Parser) Error!*const ast.Expr {
        const t = p.tok;
        const s = span(t, t);
        switch (t.tag) {
            .number => {
                // The lexer only lets `[0-9.eE+-]` through, in JS DecimalLiteral shape.
                const value = std.fmt.parseFloat(f64, t.text(p.source())) catch unreachable;
                try p.advance();
                return p.node(s, .{ .number = value }, 0);
            },
            .string => {
                const units = try p.decodeString(t);
                try p.advance();
                return p.node(s, .{ .string = units }, 0);
            },
            .kw_true, .kw_false => {
                try p.advance();
                return p.node(s, .{ .boolean = t.tag == .kw_true }, 0);
            },
            .kw_null => {
                try p.advance();
                return p.node(s, .null, 0);
            },
            .identifier => {
                const name = t.text(p.source());
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
                if (p.tok.tag == .r_paren) return p.fail(.{ .unsupported = .syntax }, p.tok);
                const inner = try p.expression();
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
            // `in` and `instanceof` are binary operators.
            .identifier => !p.isText(t, "in") and !p.isText(t, "instanceof"),
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

    /// Decodes a string literal token (quotes included) to UTF-16 code units
    /// (LANGUAGE.md §3). The lexer has already found the closing quote.
    fn decodeString(p: *Parser, t: Token) Error![]const u16 {
        const base = t.start + 1;
        const s = p.source()[base .. t.end - 1];
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
