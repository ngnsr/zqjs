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
pub fn parse(arena: Allocator, source: []const u8, limits: Limits, diag: *Diagnostic) Error!ast.Script {
    if (source.len > limits.max_source_bytes) {
        diag.* = .{ .detail = .{ .limit_exceeded = .source_bytes } };
        return error.LimitExceeded;
    }
    var p: Parser = .{ .lexer = .init(source, diag), .arena = arena, .limits = limits, .tok = undefined };
    p.tok = try p.lexer.next();

    var statements: std.ArrayList(ast.Stmt) = .empty;
    while (p.tok.tag != .eof) {
        if (p.tok.tag == .semicolon) { // empty statement
            try p.advance();
            continue;
        }
        const e = try p.expression(0);
        try p.endStatement();
        try statements.append(arena, .{ .expression = e });
    }
    return .{ .statements = statements.items };
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

const Parser = struct {
    lexer: Lexer,
    tok: Token,
    arena: Allocator,
    limits: Limits,
    /// Current recursion depth of `expression`.
    depth: u32 = 0,

    fn advance(p: *Parser) Error!void {
        p.tok = try p.lexer.next();
    }

    fn source(p: *const Parser) []const u8 {
        return p.lexer.source;
    }

    fn expression(p: *Parser, min_bp: u8) Error!*const ast.Expr {
        p.depth += 1;
        defer p.depth -= 1;
        if (p.depth > p.limits.max_nesting_depth) return p.limitExceeded(p.tok.start, p.tok.end);

        var lhs = try p.prefix();
        while (true) {
            if (p.tok.tag == .eq2 or p.tok.tag == .neq2) return p.fail(.{ .unsupported = .loose_equality }, p.tok);
            const info = infix(p.tok.tag) orelse break;
            if (info.bp < min_bp) break;
            try p.advance();
            const rhs = try p.expression(if (info.right_assoc) info.bp else info.bp + 1);
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
        const span: ast.Span = .{ .start = t.start, .end = t.end };
        switch (t.tag) {
            .number => {
                // The lexer only lets `[0-9.eE+-]` through, in JS DecimalLiteral shape.
                const value = std.fmt.parseFloat(f64, t.text(p.source())) catch unreachable;
                try p.advance();
                return p.node(span, .{ .number = value }, 0);
            },
            .string => {
                const units = try p.decodeString(t);
                try p.advance();
                return p.node(span, .{ .string = units }, 0);
            },
            .kw_true, .kw_false => {
                try p.advance();
                return p.node(span, .{ .boolean = t.tag == .kw_true }, 0);
            },
            .kw_null => {
                try p.advance();
                return p.node(span, .null, 0);
            },
            .l_paren => {
                try p.advance();
                // `()` is only valid as an arrow-function parameter list.
                if (p.tok.tag == .r_paren) return p.fail(.{ .unsupported = .syntax }, p.tok);
                const inner = try p.expression(0);
                if (p.tok.tag != .r_paren) return p.unexpectedAfterExpression(p.tok);
                try p.advance();
                return inner;
            },
            .minus, .plus, .bang => {
                try p.advance();
                const operand = try p.expression(unary_bp);
                // JS forbids `-a ** b`: it is ambiguous whether `-` applies before or after `**`.
                if (p.tok.tag == .star_star)
                    return p.fail(.{ .syntax_error = "unary operator before '**' needs parentheses" }, t);
                const op: ast.UnaryOp = switch (t.tag) {
                    .minus => .neg,
                    .plus => .plus,
                    else => .not,
                };
                return p.node(.{ .start = t.start, .end = operand.span.end }, .{ .unary = .{ .op = op, .operand = operand } }, operand.depth);
            },
            // Tokens that cannot begin an expression in any JavaScript.
            .eof, .semicolon, .r_paren, .r_bracket, .r_brace, .comma, .star, .star_star, .percent, .eq3, .neq3, .eq2, .neq2, .lt, .le, .gt, .ge, .amp_amp, .pipe_pipe, .question2, .question, .question_dot, .colon, .eq, .arrow => return p.fail(.{ .syntax_error = "unexpected token" }, t),
            // Identifiers, `[`, `{`, `/` (regex), `~`, `++`, `...`, … may start valid JS.
            else => return p.fail(.{ .unsupported = .syntax }, t),
        }
    }

    fn endStatement(p: *Parser) Error!void {
        const t = p.tok;
        if (t.tag == .semicolon) return p.advance();
        if (t.newline_before or t.tag == .eof or t.tag == .r_brace) return p.fail(.{ .unsupported = .asi }, t);
        return p.unexpectedAfterExpression(t);
    }

    /// `t` follows a complete expression but is not what the grammar expects.
    /// It is a SyntaxError only if no JavaScript operator or construct can follow an
    /// expression with this token (and, at statement level, ASI does not apply).
    fn unexpectedAfterExpression(p: *Parser, t: Token) Error {
        const certain = switch (t.tag) {
            .number, .string, .kw_true, .kw_false, .kw_null, .r_paren, .r_bracket, .r_brace, .semicolon, .eof => true,
            // `in` and `instanceof` are binary operators.
            .identifier => !std.mem.eql(u8, t.text(p.source()), "in") and !std.mem.eql(u8, t.text(p.source()), "instanceof"),
            else => false,
        };
        if (certain) return p.fail(.{ .syntax_error = "unexpected token" }, t);
        return p.fail(.{ .unsupported = .syntax }, t);
    }

    fn node(p: *Parser, span: ast.Span, data: ast.Expr.Data, child_depth: u16) Error!*const ast.Expr {
        const depth = @as(u32, child_depth) + 1;
        if (depth > p.limits.max_nesting_depth) return p.limitExceeded(span.start, span.end);
        const e = try p.arena.create(ast.Expr);
        e.* = .{ .span = span, .depth = @intCast(depth), .data = data };
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
    try testing.expectEqualSlices(u16, expected, script.statements[0].expression.data.string);
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

/// `((…(1)…));` with n parentheses, or `1+1+…+1;` with n additions.
fn nestedSource(a: Allocator, n: usize, comptime kind: enum { parens, chain }) ![]u8 {
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

    try testing.expectError(error.LimitExceeded, parse(a, try nestedSource(a, 60, .parens), limits, &d));
    try testing.expectEqual(@import("../limits.zig").Limit.nesting_depth, d.detail.limit_exceeded);
    // A left-associative chain is parsed by a loop, but builds a 60-deep tree.
    try testing.expectError(error.LimitExceeded, parse(a, try nestedSource(a, 60, .chain), limits, &d));

    // Just under the limit is fine.
    _ = try parse(a, try nestedSource(a, 48, .parens), limits, &d);
    _ = try parse(a, try nestedSource(a, 48, .chain), limits, &d);
}

fn parseUnderAllocator(allocator: Allocator, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    _ = parse(arena.allocator(), source, .{}, &d) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
}

test "error paths: every allocation failing once leaks nothing" {
    const sources = [_][]const u8{
        "1 + 2 * 3; 'a\\u{1F600}b'; -(4 ** 2) / 5 % 6;",
        "1 + 2; 3 *",
        "((1 + 2) * 'x') === null && !true || 2 ** 3 ** 2;",
    };
    for (sources) |src| try testing.checkAllAllocationFailures(testing.allocator, parseUnderAllocator, .{src});
}

fn fuzzOne(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [1024]u8 = undefined;
    const src = buf[0..smith.slice(&buf)];
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    if (parse(arena.allocator(), src, .{ .max_nesting_depth = 64 }, &d)) |script| {
        var discard: std.Io.Writer.Discarding = .init(&.{});
        try ast.dump(script, &discard.writer);
    } else |err| {
        if (err == error.OutOfMemory) return err;
        try testing.expect(d.start <= d.end and d.end <= src.len);
    }
}

test "fuzz: parser accepts or diagnoses any input without crashing" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        "1 + 2 * 3;",
        "'\\u{1F600}\\uD800' === \"x\";",
        "(-2) ** 2 ** 3 < 4 && !null || .5e3;",
        "1 /* c */ // d\n;",
    } });
}
