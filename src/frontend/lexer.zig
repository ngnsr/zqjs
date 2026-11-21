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
            const tag = try l.number();
            return l.make(tag, start, newline_before);
        }
        if (isIdentStart(c)) {
            while (isIdentPart(l.peekAt(l.pos))) l.pos += 1;
            return l.make(keyword(l.source[start..l.pos]), start, newline_before);
        }
        if (c == '#' and isIdentStart(l.peekAt(start + 1))) {
            l.pos += 1;
            while (isIdentPart(l.peekAt(l.pos))) l.pos += 1;
            return l.make(.private_ident, start, newline_before);
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
                // `?.` followed by a decimal digit is `?` then a `.5`-style number
                // (ECMAScript OptionalChainPunctuator :: ?. [lookahead not in DecimalDigit]).
                if (p[1] == .question_dot and isDigit(l.peekAt(start + 2))) continue;
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

    /// `digits [. digits] [e [+-] digits]`, `. digits [exponent]`, or `0x`/`0o`/`0b` digits;
    /// `_` separators only between two digits. Returns `.bigint` if suffixed with `n`.
    fn number(l: *Lexer) Error!Tag {
        const start = l.pos;
        if (l.source[start] == '0') {
            const radix: u8 = switch (l.peekAt(start + 1)) {
                'x', 'X' => 16,
                'o', 'O' => 8,
                'b', 'B' => 2,
                '0'...'9' => {
                    var scan = start + 1;
                    while (isDigit(l.peekAt(scan)) or l.peekAt(scan) == '_') scan += 1;
                    if (l.peekAt(scan) == 'n') {
                        return l.fail(.{ .syntax_error = "Decimal BigInt literal cannot have leading zero" }, start, scan + 1);
                    }
                    return l.fail(.{ .unsupported = .legacy_octal }, start, start + 2);
                },
                '_' => return l.fail(.{ .syntax_error = "numeric separator after a leading 0" }, start + 1, start + 2),
                else => 10,
            };
            if (radix != 10) {
                l.pos = start + 2;
                if (!isRadixDigit(l.peekAt(l.pos), radix)) return l.fail(.{ .syntax_error = "missing digits after the radix prefix" }, start, l.pos);
                try l.digits(radix);
                return l.numberEnd(start, false);
            }
        }
        var is_float = l.source[start] == '.';
        try l.digits(10);
        if (l.peekAt(l.pos) == '.') {
            is_float = true;
            l.pos += 1;
            try l.digits(10);
        }
        if (l.peekAt(l.pos) == 'e' or l.peekAt(l.pos) == 'E') {
            is_float = true;
            l.pos += 1;
            if (l.peekAt(l.pos) == '+' or l.peekAt(l.pos) == '-') l.pos += 1;
            if (!isDigit(l.peekAt(l.pos))) return l.fail(.{ .syntax_error = "missing digits in exponent" }, start, l.pos);
            try l.digits(10);
        }
        return l.numberEnd(start, is_float);
    }

    fn numberEnd(l: *Lexer, start: usize, is_float: bool) Error!Tag {
        const after = l.peekAt(l.pos);
        if (after == 'n') {
            if (is_float) return l.fail(.{ .syntax_error = "Invalid or unexpected token" }, start, l.pos + 1);
            l.pos += 1;
            if (isIdentPart(l.peekAt(l.pos))) return l.fail(.{ .syntax_error = "identifier or digit directly after a number" }, l.pos, l.pos + 1);
            return .bigint;
        }
        if (isIdentPart(after)) return l.fail(.{ .syntax_error = "identifier or digit directly after a number" }, l.pos, l.pos + 1);
        return .number;
    }

    /// A run of digits, possibly empty; each `_` must sit between two digits.
    fn digits(l: *Lexer, radix: u8) Error!void {
        while (true) {
            const c = l.peekAt(l.pos);
            if (isRadixDigit(c, radix)) {
                l.pos += 1;
            } else if (c == '_') {
                const prev_digit = l.pos > 0 and isRadixDigit(l.source[l.pos - 1], radix);
                if (!prev_digit or !isRadixDigit(l.peekAt(l.pos + 1), radix))
                    return l.fail(.{ .syntax_error = "numeric separator must be between digits" }, l.pos, l.pos + 1);
                l.pos += 1;
            } else return;
        }
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

    pub const ScannedRegExp = struct {
        pattern: []const u8,
        flags: []const u8,
        end: u32,
    };

    /// Re-scans from `start` (the opening `/` of a `.slash` or `.slash_eq` token) as a
    /// `/pattern/flags` literal when the parser is in prefix expression position (D61).
    pub fn scanRegExp(l: *Lexer, start: u32) Error!ScannedRegExp {
        var i: usize = start + 1;
        var in_class = false;
        const body_end: usize = while (i < l.source.len) {
            const c = l.source[i];
            if (isLineTerminatorAt(l.source, i)) {
                return l.fail(.{ .syntax_error = "unterminated regular expression literal" }, start, i);
            }
            if (c == '\\') {
                i += 1;
                if (i >= l.source.len or isLineTerminatorAt(l.source, i)) {
                    return l.fail(.{ .syntax_error = "unterminated regular expression literal" }, start, i);
                }
                i += 1;
                continue;
            }
            if (c == '[') {
                in_class = true;
                i += 1;
                continue;
            }
            if (c == ']') {
                in_class = false;
                i += 1;
                continue;
            }
            if (c == '/' and !in_class) break i;
            i += 1;
        } else return l.fail(.{ .syntax_error = "unterminated regular expression literal" }, start, i);

        i += 1; // closing `/`
        const flags_start = i;
        while (i < l.source.len and isIdentPart(l.source[i])) i += 1;
        if (i < l.source.len and l.source[i] == '\\') {
            return l.fail(.{ .syntax_error = "invalid regular expression flag" }, flags_start, i + 1);
        }
        l.pos = @intCast(i);
        return .{
            .pattern = l.source[start + 1 .. body_end],
            .flags = l.source[flags_start..i],
            .end = @intCast(i),
        };
    }

    fn isLineTerminatorAt(s: []const u8, i: usize) bool {
        const c = s[i];
        if (c == '\n' or c == '\r') return true;
        if (c == 0xE2 and i + 2 < s.len and s[i + 1] == 0x80 and (s[i + 2] == 0xA8 or s[i + 2] == 0xA9)) return true;
        return false;
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

fn isRadixDigit(c: u8, radix: u8) bool {
    const d = std.fmt.charToDigit(c, radix) catch return false;
    return d < radix;
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
    try expectTags("0x1F 0XaB 0o17 0O7 0b101 0B1 1_000 1_0.0_1e1_0 0x1_f 0b1_0 0.0_1", &.{ .number, .number, .number, .number, .number, .number, .number, .number, .number, .number, .number });
    const sep = "numeric separator must be between digits";
    for ([_][]const u8{ "1__0", "1_", "1_.5", "1._5", "1e1_", "0x1_", "0x1__2", "1_e5" }) |s|
        try expectFailure(s, error.SyntaxError, .{ .syntax_error = sep });
    try expectFailure("1e_1", error.SyntaxError, .{ .syntax_error = "missing digits in exponent" });
    try expectFailure("0_1", error.SyntaxError, .{ .syntax_error = "numeric separator after a leading 0" });
    try expectFailure("0x_1", error.SyntaxError, .{ .syntax_error = "missing digits after the radix prefix" });
    try expectFailure("0x", error.SyntaxError, .{ .syntax_error = "missing digits after the radix prefix" });
    try expectFailure("0b2", error.SyntaxError, .{ .syntax_error = "missing digits after the radix prefix" });
    try expectFailure("0b12", error.SyntaxError, .{ .syntax_error = "identifier or digit directly after a number" });
    try expectFailure("0o8", error.SyntaxError, .{ .syntax_error = "missing digits after the radix prefix" });
    try expectFailure("0x1g", error.SyntaxError, .{ .syntax_error = "identifier or digit directly after a number" });
    try expectTags("10n 0x10n 0o77n 0b101n 123_456n", &.{ .bigint, .bigint, .bigint, .bigint, .bigint });
    try expectFailure("01n", error.SyntaxError, .{ .syntax_error = "Decimal BigInt literal cannot have leading zero" });
    try expectFailure("1.5n", error.SyntaxError, .{ .syntax_error = "Invalid or unexpected token" });
    try expectFailure("1e5n", error.SyntaxError, .{ .syntax_error = "Invalid or unexpected token" });
    try expectFailure("1__0n", error.SyntaxError, .{ .syntax_error = sep });
    try expectFailure("0x_1n", error.SyntaxError, .{ .syntax_error = "missing digits after the radix prefix" });
    try expectFailure("10_n", error.SyntaxError, .{ .syntax_error = sep });
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
