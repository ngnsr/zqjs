//! Pull-based tokenizer. It borrows the source and allocates nothing.
//!
//! String literals are only *delimited* here; escapes are decoded (and validated) by
//! the parser, which owns an allocator. Number literals are fully validated here,
//! because `std.fmt.parseFloat` would happily accept non-JS text such as `1_0`
//! or `inf` (DESIGN_DECISIONS D18).

const std = @import("std");
const token = @import("token.zig");
const Token = token.Token;
const Tag = token.Tag;
const Diagnostic = @import("diag.zig").Diagnostic;
const Feature = @import("diag.zig").Feature;

pub const Error = error{ SyntaxError, Unsupported };

pub const Lexer = struct {
    source: []const u8,
    pos: u32 = 0,
    diag: *Diagnostic,

    pub fn init(source: []const u8, diag: *Diagnostic) Lexer {
        std.debug.assert(source.len < std.math.maxInt(u32)); // callers enforce Limits.max_source_bytes
        return .{ .source = source, .diag = diag };
    }

    pub fn next(l: *Lexer) Error!Token {
        const newline_before = try l.skipTrivia();
        const start = l.pos;
        if (start >= l.source.len) return l.make(.eof, start, newline_before);
        const c = l.source[start];

        if (isDigit(c) or (c == '.' and isDigit(l.peekAt(start + 1)))) {
            try l.number();
            return l.make(.number, start, newline_before);
        }
        if (isIdentStart(c)) {
            while (isIdentPart(l.peekAt(l.pos))) l.pos += 1;
            return l.make(keyword(l.source[start..l.pos]), start, newline_before);
        }
        if (c == '\'' or c == '"') {
            try l.string(c);
            return l.make(.string, start, newline_before);
        }
        if (c == '`') {
            return l.templatePart(start, newline_before, false);
        }
        if (c >= 0x80) {
            const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
            return l.fail(.{ .unsupported = .non_ascii_source }, start, @min(start + len, l.source.len));
        }
        for (token.punctuators) |p| {
            if (std.mem.startsWith(u8, l.source[start..], p[0])) {
                l.pos += @intCast(p[0].len);
                return l.make(p[1], start, newline_before);
            }
        }
        l.pos += 1; // `#`, `@`, `` ` ``, `\`, control characters
        return l.make(.unknown, start, newline_before);
    }

    fn make(l: *Lexer, tag: Tag, start: u32, newline_before: bool) Token {
        return .{ .tag = tag, .start = start, .end = l.pos, .newline_before = newline_before };
    }

    fn fail(l: *Lexer, detail: Diagnostic.Detail, start: usize, end: usize) Error {
        l.diag.* = .{ .detail = detail, .start = @intCast(start), .end = @intCast(end) };
        return switch (detail) {
            .syntax_error => error.SyntaxError,
            .unsupported => error.Unsupported,
            .limit_exceeded => unreachable, // the lexer enforces no limits
        };
    }

    fn peekAt(l: *const Lexer, i: usize) u8 {
        return if (i < l.source.len) l.source[i] else 0;
    }

    /// Skips whitespace and comments; reports whether a line terminator was crossed.
    fn skipTrivia(l: *Lexer) Error!bool {
        var newline = false;
        while (l.pos < l.source.len) {
            switch (l.source[l.pos]) {
                ' ', '\t', 0x0B, 0x0C => l.pos += 1,
                '\n', '\r' => {
                    newline = true;
                    l.pos += 1;
                },
                '/' => switch (l.peekAt(l.pos + 1)) {
                    '/' => {
                        while (l.pos < l.source.len and l.source[l.pos] != '\n' and l.source[l.pos] != '\r') l.pos += 1;
                    },
                    '*' => {
                        const start = l.pos;
                        const close = std.mem.indexOfPos(u8, l.source, start + 2, "*/") orelse
                            return l.fail(.{ .syntax_error = "unterminated comment" }, start, start + 2);
                        if (std.mem.indexOfAny(u8, l.source[start..close], "\r\n") != null) newline = true;
                        l.pos = @intCast(close + 2);
                    },
                    else => return newline,
                },
                else => return newline,
            }
        }
        return newline;
    }

    /// DecimalLiteral only: `digits [. digits] [e [+-] digits]` or `. digits [exponent]`.
    fn number(l: *Lexer) Error!void {
        const start = l.pos;
        if (l.source[start] == '0') {
            switch (l.peekAt(start + 1)) {
                'x', 'X', 'o', 'O', 'b', 'B' => return l.fail(.{ .unsupported = .non_decimal_literal }, start, start + 2),
                '0'...'9' => return l.fail(.{ .unsupported = .legacy_octal }, start, start + 2),
                else => {},
            }
        }
        l.digits();
        if (l.peekAt(l.pos) == '.') {
            l.pos += 1;
            l.digits();
        }
        if (l.peekAt(l.pos) == 'e' or l.peekAt(l.pos) == 'E') {
            l.pos += 1;
            if (l.peekAt(l.pos) == '+' or l.peekAt(l.pos) == '-') l.pos += 1;
            if (l.peekAt(l.pos) == '_') return l.fail(.{ .unsupported = .numeric_separator }, l.pos, l.pos + 1);
            if (!isDigit(l.peekAt(l.pos))) return l.fail(.{ .syntax_error = "missing digits in exponent" }, start, l.pos);
            l.digits();
        }
        const after = l.peekAt(l.pos);
        if (after == '_') return l.fail(.{ .unsupported = .numeric_separator }, l.pos, l.pos + 1);
        if (after == 'n') return l.fail(.{ .unsupported = .bigint }, start, l.pos + 1);
        if (isIdentPart(after)) return l.fail(.{ .syntax_error = "identifier or digit directly after a number" }, l.pos, l.pos + 1);
    }

    fn digits(l: *Lexer) void {
        while (isDigit(l.peekAt(l.pos))) l.pos += 1;
    }

    /// Finds the closing quote. An escaped character is skipped without interpretation;
    /// `\` + CRLF counts as one escaped line terminator.
    fn string(l: *Lexer, quote: u8) Error!void {
        const start = l.pos;
        l.pos += 1;
        while (true) {
            if (l.pos >= l.source.len) return l.fail(.{ .syntax_error = "unterminated string literal" }, start, l.pos);
            const c = l.source[l.pos];
            if (c == quote) {
                l.pos += 1;
                return;
            }
            if (c == '\n' or c == '\r') return l.fail(.{ .syntax_error = "unterminated string literal" }, start, l.pos);
            if (c == '\\') {
                l.pos += 1;
                if (l.pos >= l.source.len) continue; // reported as unterminated
                if (l.source[l.pos] == '\r' and l.peekAt(l.pos + 1) == '\n') l.pos += 1;
            }
            l.pos += 1;
        }
    }

    /// Scans the rest of a template literal starting right after `${...}`'s `}`.
    pub fn nextTemplatePart(l: *Lexer) Error!Token {
        return l.templatePart(l.pos, false, true);
    }

    fn templatePart(l: *Lexer, start: u32, newline_before: bool, is_continuation: bool) Error!Token {
        if (!is_continuation) l.pos += 1; // skip opening `` ` ``
        while (true) {
            if (l.pos >= l.source.len) return l.fail(.{ .syntax_error = "unterminated template literal" }, start, l.pos);
            const c = l.source[l.pos];
            if (c == '`') {
                l.pos += 1;
                return l.make(if (is_continuation) .template_tail else .template_no_sub, start, newline_before);
            }
            if (c == '$' and l.peekAt(l.pos + 1) == '{') {
                l.pos += 2;
                return l.make(if (is_continuation) .template_middle else .template_head, start, newline_before);
            }
            if (c == '\\') {
                l.pos += 1;
                if (l.pos >= l.source.len) continue;
                if (l.source[l.pos] == '\r' and l.peekAt(l.pos + 1) == '\n') l.pos += 1;
            }
            l.pos += 1;
        }
    }
};

fn keyword(s: []const u8) Tag {
    const map = std.StaticStringMap(Tag).initComptime(.{
        .{ "true", .kw_true },
        .{ "false", .kw_false },
        .{ "null", .kw_null },
        .{ "const", .kw_const },
        .{ "if", .kw_if },
        .{ "else", .kw_else },
        .{ "while", .kw_while },
        .{ "for", .kw_for },
        .{ "break", .kw_break },
        .{ "continue", .kw_continue },
    });
    return map.get(s) orelse .identifier;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

fn isIdentPart(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectTags(source: []const u8, expected: []const Tag) !void {
    var d: Diagnostic = .{};
    var l = Lexer.init(source, &d);
    for (expected) |tag| try testing.expectEqual(tag, (try l.next()).tag);
    try testing.expectEqual(Tag.eof, (try l.next()).tag);
}

fn expectFailure(source: []const u8, err: Error, detail: Diagnostic.Detail) !void {
    var d: Diagnostic = .{};
    var l = Lexer.init(source, &d);
    while (true) {
        const t = l.next() catch |e| {
            try testing.expectEqual(err, e);
            try testing.expectEqualDeep(detail, d.detail);
            return;
        };
        if (t.tag == .eof) return error.TestExpectedError;
    }
}

test "longest match" {
    try expectTags("a **= b", &.{ .identifier, .star_star_eq, .identifier });
    try expectTags("1 === 2 !== 3 == 4", &.{ .number, .eq3, .number, .neq3, .number, .eq2, .number });
    try expectTags(">>>= >>> >> >", &.{ .ushr_eq, .ushr, .shr, .gt });
    try expectTags("<!-- x", &.{ .unknown, .identifier });
    try expectTags("# @ \\", &.{ .unknown, .unknown, .unknown });
    try expectTags("`a`", &.{.template_no_sub});
}

test "numbers" {
    try expectTags("0 1 0.5 .5 5. 1.e3 1e+10 1E-3", &.{ .number, .number, .number, .number, .number, .number, .number, .number });
    try expectTags("1..x", &.{ .number, .dot, .identifier });
    try expectFailure("017", error.Unsupported, .{ .unsupported = .legacy_octal });
    try expectFailure("09", error.Unsupported, .{ .unsupported = .legacy_octal });
    try expectFailure("0x10", error.Unsupported, .{ .unsupported = .non_decimal_literal });
    try expectFailure("1_000", error.Unsupported, .{ .unsupported = .numeric_separator });
    try expectFailure("1e_1", error.Unsupported, .{ .unsupported = .numeric_separator });
    try expectFailure("10n", error.Unsupported, .{ .unsupported = .bigint });
    try expectFailure("1e", error.SyntaxError, .{ .syntax_error = "missing digits in exponent" });
    try expectFailure("1e+", error.SyntaxError, .{ .syntax_error = "missing digits in exponent" });
    try expectFailure("3in", error.SyntaxError, .{ .syntax_error = "identifier or digit directly after a number" });
}

test "strings are delimited, not decoded" {
    try expectTags("'a\\'b' \"\\\"\" 'x\\\r\ny'", &.{ .string, .string, .string });
    try expectFailure("'abc", error.SyntaxError, .{ .syntax_error = "unterminated string literal" });
    try expectFailure("'a\nb'", error.SyntaxError, .{ .syntax_error = "unterminated string literal" });
    try expectFailure("'a\\", error.SyntaxError, .{ .syntax_error = "unterminated string literal" });
}

test "trivia and newlines" {
    var d: Diagnostic = .{};
    var l = Lexer.init("1 // c\n2 /* a\nb */ 3 /* c */ 4", &d);
    try testing.expect(!(try l.next()).newline_before);
    try testing.expect((try l.next()).newline_before);
    try testing.expect((try l.next()).newline_before);
    try testing.expect(!(try l.next()).newline_before);
    try expectFailure("1 /* x", error.SyntaxError, .{ .syntax_error = "unterminated comment" });
}

test "non-ASCII only inside strings and comments" {
    try expectTags("'é😀' // ünïcode", &.{.string});
    try expectFailure("é", error.Unsupported, .{ .unsupported = .non_ascii_source });
    try expectFailure("1\xC2\xA0", error.Unsupported, .{ .unsupported = .non_ascii_source }); // NBSP
}
