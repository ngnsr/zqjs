//! Lexer-driven multi-line completeness check, read-only Tab completion, and
//! live syntax highlighting for the REPL (D71).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Lexer = @import("../frontend/lexer.zig").Lexer;
const token = @import("../frontend/token.zig");
const Tag = token.Tag;
const Diagnostic = @import("../frontend/diag.zig").Diagnostic;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const Value = @import("../runtime/value.zig").Value;
const heap = @import("../runtime/heap.zig");
const Object = heap.Object;
const builtins = @import("../runtime/builtins.zig");

pub const dot_commands: []const []const u8 = &.{
    ".help",
    ".exit",
    ".clear",
    ".break",
    ".editor",
    ".load",
    ".save",
    ".ast",
    ".bc",
    ".trace",
    ".gc",
    ".mem",
    ".engine",
    ".limits",
};

pub const js_keywords: []const []const u8 = &.{
    "async",
    "await",
    "break",
    "case",
    "catch",
    "class",
    "const",
    "constructor",
    "continue",
    "default",
    "delete",
    "do",
    "else",
    "export",
    "extends",
    "false",
    "finally",
    "for",
    "function",
    "if",
    "import",
    "in",
    "instanceof",
    "let",
    "new",
    "null",
    "of",
    "return",
    "static",
    "super",
    "switch",
    "this",
    "throw",
    "true",
    "try",
    "typeof",
    "var",
    "void",
    "while",
    "with",
    "yield",
};

pub const builtin_globals: []const []const u8 = &.{
    "AggregateError",
    "Array",
    "Error",
    "EvalError",
    "Function",
    "Infinity",
    "JSON",
    "Map",
    "Math",
    "NaN",
    "Number",
    "Object",
    "Promise",
    "RangeError",
    "ReferenceError",
    "RegExp",
    "Set",
    "String",
    "Symbol",
    "SyntaxError",
    "TextDecoder",
    "TextEncoder",
    "TypeError",
    "URIError",
    "atob",
    "btoa",
    "console",
    "isFinite",
    "isNaN",
    "parseFloat",
    "parseInt",
    "print",
    "undefined",
};

/// Read-only view of session bindings for Tab completion.
pub const ReplBindingLookup = struct {
    ctx: *const anyopaque,
    get: *const fn (ctx: *const anyopaque, name: []const u8) ?Value,
    list: *const fn (ctx: *const anyopaque, gpa: Allocator, out: *std.ArrayList([]const u8)) Allocator.Error!void,
};

/// Returns true if `source` is syntactically complete enough to submit to the parser
/// (no unmatched delimiters, no unterminated `/*` comment or template literal, and
/// no trailing continuation operator).
pub fn isComplete(source: []const u8) bool {
    var diag: Diagnostic = .{};
    var lex = Lexer.init(source, &diag);

    var parens: i32 = 0;
    var brackets: i32 = 0;
    var braces: i32 = 0;
    var tpl_stack: [64]i32 = undefined;
    var tpl_len: usize = 0;
    var last_tag: Tag = .eof;

    while (true) {
        const tok = lex.next() catch |e| {
            if (e == error.SyntaxError) {
                switch (diag.detail) {
                    .syntax_error => |msg| {
                        if (std.mem.eql(u8, msg, "unterminated comment") or
                            std.mem.eql(u8, msg, "unterminated template literal"))
                        {
                            return false;
                        }
                    },
                    else => {},
                }
            }
            return true;
        };
        if (tok.tag == .eof) break;
        last_tag = tok.tag;
        switch (tok.tag) {
            .l_paren => parens += 1,
            .r_paren => parens -= 1,
            .l_bracket => brackets += 1,
            .r_bracket => brackets -= 1,
            .l_brace => braces += 1,
            .r_brace => {
                if (tpl_len > 0 and braces == tpl_stack[tpl_len - 1] + 1) {
                    tpl_len -= 1;
                    braces -= 1;
                    // Continue scanning the template literal tail/middle.
                    const cont = lex.nextTemplatePart() catch |e| {
                        if (e == error.SyntaxError) {
                            switch (diag.detail) {
                                .syntax_error => |msg| {
                                    if (std.mem.eql(u8, msg, "unterminated template literal")) return false;
                                },
                                else => {},
                            }
                        }
                        return true;
                    };
                    last_tag = cont.tag;
                    while (cont.tag == .template_middle) {
                        if (tpl_len < tpl_stack.len) {
                            tpl_stack[tpl_len] = braces;
                            tpl_len += 1;
                        }
                        braces += 1;
                        break;
                    }
                    continue;
                }
                braces -= 1;
            },
            .template_head => {
                if (tpl_len < tpl_stack.len) {
                    tpl_stack[tpl_len] = braces;
                    tpl_len += 1;
                }
                braces += 1;
            },
            else => {},
        }
    }

    if (parens > 0 or brackets > 0 or braces > 0 or tpl_len > 0) return false;
    return !isContinuationTag(last_tag);
}

fn isContinuationTag(tag: Tag) bool {
    return switch (tag) {
        .arrow,
        .plus,
        .minus,
        .star,
        .slash,
        .percent,
        .star_star,
        .amp_amp,
        .pipe_pipe,
        .question2,
        .eq,
        .comma,
        .dot,
        .question_dot,
        .colon,
        .question,
        .shl,
        .shr,
        .ushr,
        .amp,
        .pipe,
        .caret,
        .eq3,
        .neq3,
        .eq2,
        .neq2,
        .lt,
        .le,
        .gt,
        .ge,
        .plus_eq,
        .minus_eq,
        .star_eq,
        .slash_eq,
        .percent_eq,
        .star_star_eq,
        .shl_eq,
        .shr_eq,
        .ushr_eq,
        .amp_eq,
        .caret_eq,
        .pipe_eq,
        .amp_amp_eq,
        .pipe_pipe_eq,
        .question2_eq,
        => true,
        else => false,
    };
}

pub const CompletionResult = struct {
    /// Byte offset in `line` where the completed token/prefix starts.
    replace_start: usize,
    /// Sorted, deduplicated candidate strings (allocated with `gpa`).
    matches: [][]const u8,

    pub fn deinit(self: *CompletionResult, gpa: Allocator) void {
        for (self.matches) |m| gpa.free(m);
        gpa.free(self.matches);
        self.* = undefined;
    }
};

/// Computes Tab-completion candidates at `cursor` in `line`.
/// Strictly read-only: never invokes getters or runs JS code.
pub fn complete(
    gpa: Allocator,
    line: []const u8,
    cursor: usize,
    rt: *const Runtime,
    repl_lookup: ?ReplBindingLookup,
) Allocator.Error!CompletionResult {
    const pos = @min(cursor, line.len);
    const before = line[0..pos];

    var raw: std.ArrayList([]const u8) = .empty;
    defer {
        for (raw.items) |s| gpa.free(s);
        raw.deinit(gpa);
    }

    // 1. Dot-command completion at start of line.
    const trimmed_left = std.mem.trimStart(u8, before, " \t");
    if (std.mem.startsWith(u8, trimmed_left, ".") and std.mem.indexOfAny(u8, trimmed_left, " \t") == null) {
        const start = pos - trimmed_left.len;
        for (dot_commands) |cmd| {
            if (std.mem.startsWith(u8, cmd, trimmed_left)) {
                try raw.append(gpa, try gpa.dupe(u8, cmd));
            }
        }
        return finishCompletions(gpa, start, raw.items);
    }

    // 2. Extract identifier prefix and check for dotted property chain (`a.b.pref`).
    var prefix_start = pos;
    while (prefix_start > 0 and isIdentChar(before[prefix_start - 1])) {
        prefix_start -= 1;
    }
    const prefix = before[prefix_start..pos];

    if (prefix_start > 0 and before[prefix_start - 1] == '.') {
        // Walk back to collect the dotted chain `root.prop1.prop2`.
        var chain_end = prefix_start - 1;
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(gpa);

        while (true) {
            var seg_start = chain_end;
            while (seg_start > 0 and isIdentChar(before[seg_start - 1])) {
                seg_start -= 1;
            }
            const seg = before[seg_start..chain_end];
            if (seg.len == 0) {
                parts.clearRetainingCapacity();
                break;
            }
            try parts.append(gpa, seg);
            if (seg_start > 0 and before[seg_start - 1] == '.') {
                chain_end = seg_start - 1;
            } else {
                break;
            }
        }

        if (parts.items.len > 0) {
            // `parts` is reversed (innermost first).
            const root_name = parts.items[parts.items.len - 1];
            var cur_val: ?Value = resolveRootValue(rt, repl_lookup, root_name);
            var i: usize = parts.items.len - 1;
            while (i > 0 and cur_val != null) {
                i -= 1;
                cur_val = readOnlyProperty(rt, cur_val.?, parts.items[i]);
            }
            if (cur_val) |target| {
                try collectProperties(gpa, rt, target, prefix, &raw);
            }
        }
        return finishCompletions(gpa, prefix_start, raw.items);
    }

    // 3. Top-level identifier / keyword / global / session binding completion.
    for (js_keywords) |kw| {
        if (std.mem.startsWith(u8, kw, prefix)) {
            try raw.append(gpa, try gpa.dupe(u8, kw));
        }
    }
    for (builtin_globals) |g| {
        if (std.mem.startsWith(u8, g, prefix)) {
            try raw.append(gpa, try gpa.dupe(u8, g));
        }
    }
    for (rt.host_globals.items) |hg| {
        if (std.mem.startsWith(u8, hg.name, prefix)) {
            try raw.append(gpa, try gpa.dupe(u8, hg.name));
        }
    }
    if (repl_lookup) |rl| {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        try rl.list(rl.ctx, gpa, &names);
        for (names.items) |n| {
            if (std.mem.startsWith(u8, n, prefix)) {
                try raw.append(gpa, try gpa.dupe(u8, n));
            }
        }
    }

    return finishCompletions(gpa, prefix_start, raw.items);
}

fn finishCompletions(gpa: Allocator, replace_start: usize, items: []const []const u8) Allocator.Error!CompletionResult {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |s| gpa.free(s);
        list.deinit(gpa);
    }
    for (items) |item| {
        var dup = false;
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, item)) {
                dup = true;
                break;
            }
        }
        if (!dup) {
            try list.append(gpa, try gpa.dupe(u8, item));
        }
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return .{
        .replace_start = replace_start,
        .matches = try list.toOwnedSlice(gpa),
    };
}

pub fn longestCommonPrefix(matches: []const []const u8) []const u8 {
    if (matches.len == 0) return "";
    var lcp = matches[0];
    for (matches[1..]) |m| {
        const limit = @min(lcp.len, m.len);
        var i: usize = 0;
        while (i < limit and lcp[i] == m[i]) : (i += 1) {}
        lcp = lcp[0..i];
    }
    return lcp;
}

fn resolveRootValue(rt: *const Runtime, repl_lookup: ?ReplBindingLookup, name: []const u8) ?Value {
    if (repl_lookup) |rl| {
        if (rl.get(rl.ctx, name)) |v| return v;
    }
    if (rt.realm) |r| {
        if (std.mem.eql(u8, name, "Math")) return Value.fromObject(r.math);
        if (std.mem.eql(u8, name, "JSON")) return Value.fromObject(r.json);
        if (std.mem.eql(u8, name, "console")) return Value.fromObject(r.console);
        if (std.mem.eql(u8, name, "Object")) return Value.fromObject(r.object_namespace);
        if (std.mem.eql(u8, name, "Array")) return Value.fromObject(r.array_namespace);
        if (std.mem.eql(u8, name, "String")) return Value.fromObject(r.string_namespace);
        if (std.mem.eql(u8, name, "Number")) return Value.fromObject(r.number_namespace);
        if (std.mem.eql(u8, name, "Map")) return Value.fromObject(r.map_namespace);
        if (std.mem.eql(u8, name, "Set")) return Value.fromObject(r.set_namespace);
        if (std.mem.eql(u8, name, "Promise")) return Value.fromObject(r.promise_namespace);
        if (std.mem.eql(u8, name, "Symbol")) return Value.fromObject(r.symbol_namespace);
        if (std.mem.eql(u8, name, "RegExp")) return Value.fromObject(r.regexp_namespace);
    }
    return null;
}

fn readOnlyProperty(rt: *const Runtime, target: Value, name: []const u8) ?Value {
    const obj: *const Object = switch (target.unpack()) {
        .object => |o| o,
        .string => if (rt.realm) |r| r.string_prototype else return null,
        .number => if (rt.realm) |r| r.number_prototype else return null,
        .closure => if (rt.realm) |r| r.function_prototype else return null,
        else => return null,
    };
    var cur: ?*const Object = obj;
    var steps: usize = 0;
    while (cur) |o| : (steps += 1) {
        if (steps > 64) break;
        var it = o.props.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.isSymbol()) continue;
            if (utf16EqlAscii(entry.key_ptr.asAtom().units, name)) {
                // Strictly read-only: never invoke getters.
                if (entry.value_ptr.is_accessor) return null;
                return entry.value_ptr.value;
            }
        }
        cur = o.proto;
    }
    return null;
}

fn collectProperties(
    gpa: Allocator,
    rt: *const Runtime,
    target: Value,
    prefix: []const u8,
    out: *std.ArrayList([]const u8),
) Allocator.Error!void {
    const obj: ?*const Object = switch (target.unpack()) {
        .object => |o| o,
        .string => if (rt.realm) |r| r.string_prototype else null,
        .number => if (rt.realm) |r| r.number_prototype else null,
        .closure => if (rt.realm) |r| r.function_prototype else null,
        else => null,
    };

    if (target.isObject() and target.asObject().kind == .array) {
        if (std.mem.startsWith(u8, "length", prefix)) {
            try out.append(gpa, try gpa.dupe(u8, "length"));
        }
    } else if (target.isString()) {
        if (std.mem.startsWith(u8, "length", prefix)) {
            try out.append(gpa, try gpa.dupe(u8, "length"));
        }
    }

    var cur = obj;
    var steps: usize = 0;
    while (cur) |o| : (steps += 1) {
        if (steps > 64) break;
        var it = o.props.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.isSymbol()) continue;
            const units = entry.key_ptr.asAtom().units;
            if (utf16StartsWithAscii(units, prefix)) {
                if (utf16ToAsciiAlloc(gpa, units)) |ascii| {
                    try out.append(gpa, ascii);
                } else |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.NonAscii => {},
                }
            }
        }
        cur = o.proto;
    }
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '$';
}

fn utf16EqlAscii(units: []const u16, ascii: []const u8) bool {
    if (units.len != ascii.len) return false;
    for (units, ascii) |u, a| {
        if (u != a) return false;
    }
    return true;
}

fn utf16StartsWithAscii(units: []const u16, prefix: []const u8) bool {
    if (units.len < prefix.len) return false;
    for (prefix, 0..) |a, i| {
        if (units[i] != a) return false;
    }
    return true;
}

fn utf16ToAsciiAlloc(gpa: Allocator, units: []const u16) (Allocator.Error || error{NonAscii})![]const u8 {
    for (units) |u| {
        if (u > 127) return error.NonAscii;
    }
    const buf = try gpa.alloc(u8, units.len);
    for (units, 0..) |u, i| buf[i] = @intCast(u);
    return buf;
}

/// Live ANSI syntax highlighting of `line` using `Lexer`.
pub fn highlight(line: []const u8, w: *Writer) Writer.Error!void {
    var diag: Diagnostic = .{};
    var lex = Lexer.init(line, &diag);
    var pos: usize = 0;

    while (true) {
        const tok = lex.next() catch {
            // Write trivia/tail safely while user is mid-typing an unterminated literal/comment.
            if (pos < line.len) {
                const rest = line[pos..];
                if (std.mem.indexOf(u8, rest, "/*")) |cmt_off| {
                    try w.writeAll(rest[0..cmt_off]);
                    try w.print("\x1b[90m{s}\x1b[0m", .{rest[cmt_off..]});
                } else {
                    try w.writeAll(rest);
                }
            }
            return;
        };
        if (tok.start > pos) {
            const trivia = line[pos..tok.start];
            try writeTriviaHighlighted(trivia, w);
        }
        if (tok.tag == .eof) break;

        const text = line[tok.start..tok.end];
        const color = tokenColor(tok.tag, text);
        if (color) |c| {
            try w.print("{s}{s}\x1b[0m", .{ c, text });
        } else {
            try w.writeAll(text);
        }
        pos = tok.end;
    }
}

fn writeTriviaHighlighted(trivia: []const u8, w: *Writer) Writer.Error!void {
    var i: usize = 0;
    while (i < trivia.len) {
        if (i + 1 < trivia.len and trivia[i] == '/' and trivia[i + 1] == '/') {
            const nl = std.mem.indexOfAnyPos(u8, trivia, i + 2, "\r\n") orelse trivia.len;
            try w.print("\x1b[90m{s}\x1b[0m", .{trivia[i..nl]});
            i = nl;
        } else if (i + 1 < trivia.len and trivia[i] == '/' and trivia[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, trivia, i + 2, "*/");
            const end = if (close) |c| c + 2 else trivia.len;
            try w.print("\x1b[90m{s}\x1b[0m", .{trivia[i..end]});
            i = end;
        } else {
            try w.writeByte(trivia[i]);
            i += 1;
        }
    }
}

fn tokenColor(tag: Tag, text: []const u8) ?[]const u8 {
    return switch (tag) {
        .kw_const, .kw_if, .kw_else, .kw_while, .kw_for, .kw_break, .kw_continue => "\x1b[35m",
        .kw_true, .kw_false, .kw_null, .number, .bigint => "\x1b[33m",
        .string, .template_no_sub, .template_head, .template_middle, .template_tail => "\x1b[32m",
        .identifier => if (isContextualKeyword(text)) "\x1b[35m" else null,
        .l_paren, .r_paren, .l_brace, .r_brace, .l_bracket, .r_bracket, .semicolon, .comma, .dot, .arrow => "\x1b[36m",
        else => null,
    };
}

fn isContextualKeyword(text: []const u8) bool {
    const words = [_][]const u8{
        "let",        "function", "return", "throw",   "try",     "catch",
        "finally",    "new",      "typeof", "class",   "extends", "super",
        "static",     "async",    "await",  "yield",   "of",      "in",
        "instanceof", "switch",   "case",   "default", "do",      "this",
        "delete",     "void",     "var",
    };
    for (words) |w| {
        if (std.mem.eql(u8, text, w)) return true;
    }
    return false;
}
