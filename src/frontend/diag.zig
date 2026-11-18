//! Diagnostics: what went wrong and where. A Diagnostic holds only offsets and enums.
//! Text is produced at render time from the source, so filling one never allocates.

const std = @import("std");
const Limit = @import("../limits.zig").Limit;

/// Stable ids for `Unsupported` outcomes; listed in LANGUAGE.md §2.
pub const Feature = enum {
    asi,
    loose_equality,
    legacy_octal,
    non_ascii_source,
    invalid_utf8,
    bigint,
    global_assignment,
    function_to_string,
    block_function,
    duplicate_parameter,
    duplicate_function,
    function_name_assignment,
    arguments,
    builtin,
    sparse_array,
    user_conversion,
    sloppy_this,
    arrow_this,
    function_properties,
    primitive_write,
    regex_annex_b,
    regex_unicode_escape_braced,
    regex_unicode_property,
    syntax,

    pub fn description(f: Feature) []const u8 {
        return switch (f) {
            .function_to_string => "converting a function to a string",
            .block_function => "function declarations inside blocks or single-statement positions (Annex B)",
            .duplicate_parameter => "duplicate parameter names",
            .duplicate_function => "redeclaring a function, or a parameter, with a function declaration",
            .function_name_assignment => "assigning to a function expression's own name",
            .arguments => "the arguments object",
            .builtin => "a built-in node has that ZQJS doesn't implement yet",
            .sparse_array => "arrays with holes (deleting an element, a write past the end, growing length)",
            .user_conversion => "converting an object with a user-defined toString/valueOf/join",
            .sloppy_this => "`this` outside a method call (sloppy mode: the global object)",
            .arrow_this => "lexical `this` inside an arrow function",
            .function_properties => "properties of functions",
            .primitive_write => "writing or deleting properties of primitive values",
            .regex_annex_b => "Annex B web-reality RegExp syntax",
            .regex_unicode_escape_braced => "\\u{...} RegExp escapes without unicode mode",
            .regex_unicode_property => "\\p{...} and \\P{...} RegExp unicode property escapes without unicode mode",
            .global_assignment => "assignment to an undeclared variable",
            .asi => "automatic semicolon insertion; end the statement with ';'",
            .loose_equality => "loose equality; use '===' or '!=='",
            .legacy_octal => "legacy octal literal or escape",
            .non_ascii_source => "non-ASCII character outside a string or comment",
            .invalid_utf8 => "source is not valid UTF-8",
            .bigint => "BigInt literals",
            .syntax => "this syntax is not part of ZQJS yet",
        };
    }
};

pub const Diagnostic = struct {
    detail: Detail = .{ .syntax_error = "" },
    /// Byte span in the source the problem refers to.
    start: u32 = 0,
    end: u32 = 0,

    pub const Detail = union(enum) {
        syntax_error: []const u8, // a static message
        unsupported: Feature,
        limit_exceeded: Limit,
    };

    pub const Location = struct { line: u32, column: u32, line_start: u32, line_end: u32 };

    /// 1-based line and column (in bytes) of `offset`.
    pub fn locate(source: []const u8, offset: u32) Location {
        var line: u32 = 1;
        var line_start: u32 = 0;
        for (source[0..@min(offset, source.len)], 0..) |c, i| {
            if (c == '\n') {
                line += 1;
                line_start = @intCast(i + 1);
            }
        }
        const line_end: u32 = if (std.mem.indexOfScalarPos(u8, source, line_start, '\n')) |e| @intCast(e) else @intCast(source.len);
        return .{ .line = line, .column = offset - line_start + 1, .line_start = line_start, .line_end = line_end };
    }

    /// `name:line:col: Kind: message`, then the source line and a caret.
    pub fn render(d: Diagnostic, source: []const u8, name: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const loc = locate(source, d.start);
        try w.print("{s}:{d}:{d}: ", .{ name, loc.line, loc.column });
        switch (d.detail) {
            .syntax_error => |msg| try w.print("SyntaxError: {s}\n", .{msg}),
            .unsupported => |f| {
                try w.print("Unsupported({s}): {s}", .{ @tagName(f), f.description() });
                if (d.end > d.start and d.end - d.start <= 16) try w.print(" ('{s}')", .{source[d.start..d.end]});
                try w.writeByte('\n');
            },
            .limit_exceeded => |l| try w.print("LimitExceeded({s})\n", .{@tagName(l)}),
        }
        try w.print("  {s}\n  ", .{source[loc.line_start..loc.line_end]});
        try w.splatByteAll(' ', loc.column - 1);
        try w.writeAll("^\n");
    }
};

test "locate" {
    const src = "ab\ncd\n";
    const l = Diagnostic.locate(src, 4);
    try std.testing.expectEqual(@as(u32, 2), l.line);
    try std.testing.expectEqual(@as(u32, 2), l.column);
    try std.testing.expectEqualStrings("cd", src[l.line_start..l.line_end]);
}

test "render" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const d: Diagnostic = .{ .detail = .{ .unsupported = .loose_equality }, .start = 2, .end = 4 };
    try d.render("1 == 2;", "x.js", &w);
    try std.testing.expectEqualStrings(
        "x.js:1:3: Unsupported(loose_equality): loose equality; use '===' or '!==' ('==')\n  1 == 2;\n    ^\n",
        w.buffered(),
    );
}
