//! Unit tests and node-generated fixture tests (`tests/regex/cases.jsonl`) for `src/regex.zig`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const regex = @import("zqjs_internal").regex;
const support = @import("support.zig");

test "watchdog: this binary fails, instead of hanging, if a test gets stuck" {
    support.watchdog(@src().file);
}

const Case = struct {
    pattern: []const u8,
    flags: []const u8,
    input: []const u8,
    start: u32,
    expected: ?[]const ?[2]u32,
};

fn parseFlags(str: []const u8) regex.Flags {
    var f: regex.Flags = .{};
    for (str) |c| {
        switch (c) {
            'i' => f.ignore_case = true,
            'm' => f.multiline = true,
            's' => f.dot_all = true,
            'y' => f.sticky = true,
            else => unreachable,
        }
    }
    return f;
}

test "cases.jsonl: all fixture cases match node" {
    const gpa = testing.allocator;
    var failures: usize = 0;
    var lines = std.mem.splitScalar(u8, @embedFile("regex/cases.jsonl"), '\n');
    var line_no: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(Case, gpa, line, .{});
        defer parsed.deinit();
        const c = parsed.value;

        const pat16 = try std.unicode.utf8ToUtf16LeAlloc(gpa, c.pattern);
        defer gpa.free(pat16);
        const inp16 = try std.unicode.utf8ToUtf16LeAlloc(gpa, c.input);
        defer gpa.free(inp16);

        var diag: regex.Diagnostic = .{};
        var prog = regex.compile(gpa, pat16, parseFlags(c.flags), &diag) catch |err| {
            std.debug.print("cases.jsonl:{d} /{s}/{s}: unexpected compile error {s} ({s})\n", .{
                line_no,
                c.pattern,
                c.flags,
                @errorName(err),
                diag.message,
            });
            failures += 1;
            continue;
        };
        defer prog.deinit(gpa);

        const caps = try gpa.alloc(?regex.Range, @as(usize, prog.capture_count) + 1);
        defer gpa.free(caps);

        var steps: u64 = 1_000_000;
        const matched = try regex.exec(gpa, &prog, inp16, c.start, &steps, caps);

        if (c.expected) |exp| {
            if (!matched or exp.len != caps.len) {
                std.debug.print("cases.jsonl:{d} /{s}/{s} on \"{s}\" @{d}: expected match (len {d}), got matched={}\n", .{
                    line_no,
                    c.pattern,
                    c.flags,
                    c.input,
                    c.start,
                    exp.len,
                    matched,
                });
                failures += 1;
                continue;
            }
            var mismatch = false;
            for (exp, caps) |e_opt, g_opt| {
                if (e_opt) |e| {
                    if (g_opt) |g| {
                        if (g.start != e[0] or g.end != e[1]) mismatch = true;
                    } else mismatch = true;
                } else {
                    if (g_opt != null) mismatch = true;
                }
            }
            if (mismatch) {
                std.debug.print("cases.jsonl:{d} /{s}/{s} on \"{s}\" @{d}: capture mismatch\n  expected: {any}\n  got:      {any}\n", .{
                    line_no,
                    c.pattern,
                    c.flags,
                    c.input,
                    c.start,
                    exp,
                    caps,
                });
                failures += 1;
            }
        } else {
            if (matched) {
                std.debug.print("cases.jsonl:{d} /{s}/{s} on \"{s}\" @{d}: expected null, got {any}\n", .{
                    line_no,
                    c.pattern,
                    c.flags,
                    c.input,
                    c.start,
                    caps,
                });
                failures += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

fn expectUnsupported(pattern_utf8: []const u8, flags: regex.Flags, expected_feature: []const u8) !void {
    const gpa = testing.allocator;
    const pat16 = try std.unicode.utf8ToUtf16LeAlloc(gpa, pattern_utf8);
    defer gpa.free(pat16);
    var diag: regex.Diagnostic = .{};
    try testing.expectError(error.Unsupported, regex.compile(gpa, pat16, flags, &diag));
    try testing.expect(diag.feature != null);
    try testing.expectEqualStrings(expected_feature, diag.feature.?);
}

fn expectSyntaxError(pattern_utf8: []const u8) !void {
    const gpa = testing.allocator;
    const pat16 = try std.unicode.utf8ToUtf16LeAlloc(gpa, pattern_utf8);
    defer gpa.free(pat16);
    var diag: regex.Diagnostic = .{};
    try testing.expectError(error.SyntaxError, regex.compile(gpa, pat16, .{}, &diag));
    try testing.expect(diag.feature == null);
    try testing.expect(diag.message.len > 0);
}

fn expectSyntaxErrorWithFlags(pattern_utf8: []const u8, flags: regex.Flags) !void {
    const gpa = testing.allocator;
    const pat16 = try std.unicode.utf8ToUtf16LeAlloc(gpa, pattern_utf8);
    defer gpa.free(pat16);
    var diag: regex.Diagnostic = .{};
    try testing.expectError(error.SyntaxError, regex.compile(gpa, pat16, flags, &diag));
    try testing.expect(diag.feature == null);
    try testing.expect(diag.message.len > 0);
}

test "Unsupported features return stable diag.feature ids" {
    // Unicode property escapes (outside unicode mode)
    try expectUnsupported("\\p{ASCII}", .{}, "regex_unicode_property");
    try expectUnsupported("\\P{Letter}", .{}, "regex_unicode_property");
    try expectUnsupported("[\\p{ASCII}]", .{}, "regex_unicode_property");
    try expectUnsupported("[\\P{ASCII}]", .{}, "regex_unicode_property");

    // Braced unicode escapes
    try expectUnsupported("\\u{1234}", .{}, "regex_unicode_escape_braced");
    try expectUnsupported("[\\u{41}]", .{}, "regex_unicode_escape_braced");

    // Annex B legacy syntax
    try expectUnsupported("\\8", .{}, "regex_annex_b");
    try expectUnsupported("\\9", .{}, "regex_annex_b");
    try expectUnsupported("(a)\\2", .{}, "regex_annex_b");
    try expectUnsupported("\\01", .{}, "regex_annex_b");
    try expectUnsupported("[\\01]", .{}, "regex_annex_b");
    try expectUnsupported("[\\1]", .{}, "regex_annex_b");
    try expectUnsupported("[\\B]", .{}, "regex_annex_b");
    try expectUnsupported("\\a", .{}, "regex_annex_b");
    try expectUnsupported("[\\q]", .{}, "regex_annex_b");
    try expectUnsupported("\\x1z", .{}, "regex_annex_b");
    try expectUnsupported("\\u123z", .{}, "regex_annex_b");
    try expectUnsupported("(?=a)*", .{}, "regex_annex_b");
    try expectUnsupported("(?!a)+", .{}, "regex_annex_b");
}

test "Literal fallback for unescaped {}, ], and [\\d-a] in non-u mode" {
    const gpa = testing.allocator;
    const match_cases = [_]struct { pat: []const u8, input: []const u8, end: u32 }{
        .{ .pat = "{", .input = "{", .end = 1 },
        .{ .pat = "}", .input = "}", .end = 1 },
        .{ .pat = "a{1,x}", .input = "a{1,x}", .end = 6 },
        .{ .pat = "]", .input = "]", .end = 1 },
        .{ .pat = "[\\d-a]", .input = "5", .end = 1 },
        .{ .pat = "[\\d-a]", .input = "-", .end = 1 },
        .{ .pat = "[\\d-a]", .input = "a", .end = 1 },
        .{ .pat = "[a-\\d]", .input = "-", .end = 1 },
    };
    for (match_cases) |c| {
        const caps = (try runRegex(c.pat, .{}, c.input, 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = c.end }, caps[0].?);
    }
    try expectSyntaxErrorWithFlags("{", .{ .unicode = true });
    try expectSyntaxErrorWithFlags("}", .{ .unicode = true });
    try expectSyntaxErrorWithFlags("]", .{ .unicode = true });
    try expectSyntaxErrorWithFlags("[\\d-a]", .{ .unicode = true });
}

test "SyntaxError cases that node also rejects" {
    try expectSyntaxError("*");
    try expectSyntaxError("+");
    try expectSyntaxError("?");
    try expectSyntaxError("{1,2}");
    try expectSyntaxError("a**");
    try expectSyntaxError("a*?+");
    try expectSyntaxError("^*");
    try expectSyntaxError("$+");
    try expectSyntaxError("\\b*");
    try expectSyntaxError("\\B+");
    try expectSyntaxError("a{2,1}");
    try expectSyntaxError("(");
    try expectSyntaxError(")");
    try expectSyntaxError("((a)");
    try expectSyntaxError("(a))");
    try expectSyntaxError("(?");
    try expectSyntaxError("(?:");
    try expectSyntaxError("(?x)");
    try expectSyntaxError("[");
    try expectSyntaxError("[a");
    try expectSyntaxError("[^");
    try expectSyntaxError("[z-a]");
    try expectSyntaxError("\\");
    try expectSyntaxError("[\\");
}

test "StepLimit on catastrophic backtracking /(a+)+b/ against 40 'a's with 1e6 step budget" {
    const gpa = testing.allocator;
    const pat16 = try std.unicode.utf8ToUtf16LeAlloc(gpa, "(a+)+b");
    defer gpa.free(pat16);
    var diag: regex.Diagnostic = .{};
    var prog = try regex.compile(gpa, pat16, .{}, &diag);
    defer prog.deinit(gpa);

    var input: [40]u16 = undefined;
    @memset(&input, 'a');
    var caps: [2]?regex.Range = .{ null, null };
    var steps: u64 = 1_000_000;
    try testing.expectError(error.StepLimit, regex.exec(gpa, &prog, &input, 0, &steps, &caps));
    try testing.expectEqual(@as(u64, 0), steps);
}

test "Long greedy match over 100,000 code units succeeds within step budget" {
    const gpa = testing.allocator;
    const input = try gpa.alloc(u16, 100_000);
    defer gpa.free(input);
    @memset(input, 'x');

    for ([_][]const u8{ ".*", "x+y?", "(?:x)*" }) |pat_utf8| {
        const pat16 = try std.unicode.utf8ToUtf16LeAlloc(gpa, pat_utf8);
        defer gpa.free(pat16);
        var diag: regex.Diagnostic = .{};
        var prog = try regex.compile(gpa, pat16, .{}, &diag);
        defer prog.deinit(gpa);

        var caps: [1]?regex.Range = .{null};
        var steps: u64 = 10_000_000;
        try testing.expect(try regex.exec(gpa, &prog, input, 0, &steps, &caps));
        try testing.expectEqual(regex.Range{ .start = 0, .end = 100_000 }, caps[0].?);
    }
}

test "Nesting limit max_depth (512) returns error.TooComplex" {
    const gpa = testing.allocator;

    // Exactly 512 nested groups succeeds.
    {
        var pat = try gpa.alloc(u16, 512 * 2 + 1);
        defer gpa.free(pat);
        for (0..512) |i| {
            pat[i] = '(';
            pat[512 + 1 + i] = ')';
        }
        pat[512] = 'a';
        var diag: regex.Diagnostic = .{};
        var prog = try regex.compile(gpa, pat, .{}, &diag);
        defer prog.deinit(gpa);
        try testing.expectEqual(@as(u16, 512), prog.capture_count);
    }

    // 513 nested groups returns TooComplex.
    {
        var pat = try gpa.alloc(u16, 513 * 2 + 1);
        defer gpa.free(pat);
        for (0..513) |i| {
            pat[i] = '(';
            pat[513 + 1 + i] = ')';
        }
        pat[513] = 'a';
        var diag: regex.Diagnostic = .{};
        try testing.expectError(error.TooComplex, regex.compile(gpa, pat, .{}, &diag));
    }
}

fn compileAndExecOnce(gpa: Allocator, pattern_utf8: []const u8, input_utf8: []const u8, flags: regex.Flags) !void {
    const pat16 = try std.unicode.utf8ToUtf16LeAlloc(gpa, pattern_utf8);
    defer gpa.free(pat16);
    const inp16 = try std.unicode.utf8ToUtf16LeAlloc(gpa, input_utf8);
    defer gpa.free(inp16);

    var diag: regex.Diagnostic = .{};
    var prog = regex.compile(gpa, pat16, flags, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer prog.deinit(gpa);

    const caps = try gpa.alloc(?regex.Range, @as(usize, prog.capture_count) + 1);
    defer gpa.free(caps);

    var steps: u64 = 100_000;
    _ = regex.exec(gpa, &prog, inp16, 0, &steps, caps) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StepLimit => return,
    };
}

test "FailingAllocator sweep: allocation failure at every point leaks nothing" {
    const scenarios = [_]struct { pat: []const u8, inp: []const u8, flags: regex.Flags }{
        .{ .pat = "^(\\w+)://([^/:]+)(?::(\\d+))?(/.*)?$", .inp = "https://example.com:8080/path", .flags = .{} },
        .{ .pat = "(z)((a+)?(b+)?(c))*", .inp = "zaacbbbcac", .flags = .{} },
        .{ .pat = "(a|ab)(c|bcd)(d*)", .inp = "abcd", .flags = .{} },
        .{ .pat = "(?=(a+?))\\1b|(?!c)[a-z0-9_\\d]+", .inp = "aab", .flags = .{ .ignore_case = true } },
        .{ .pat = "((a)|b){2,4}?[\\s\\S]*$", .inp = "aba\nxyz", .flags = .{ .multiline = true, .dot_all = true } },
        .{ .pat = "((a", .inp = "a", .flags = .{} }, // fails in compile after allocations
    };
    for (scenarios) |s| {
        try testing.checkAllAllocationFailures(
            testing.allocator,
            compileAndExecOnce,
            .{ s.pat, s.inp, s.flags },
        );
    }
}

fn runRegex(
    pattern_utf8: []const u8,
    flags: regex.Flags,
    input_utf8: []const u8,
    start: u32,
) !?[]?regex.Range {
    const gpa = testing.allocator;
    const pat16 = try std.unicode.utf8ToUtf16LeAlloc(gpa, pattern_utf8);
    defer gpa.free(pat16);
    const inp16 = try std.unicode.utf8ToUtf16LeAlloc(gpa, input_utf8);
    defer gpa.free(inp16);

    var diag: regex.Diagnostic = .{};
    var prog = try regex.compile(gpa, pat16, flags, &diag);
    defer prog.deinit(gpa);

    const caps = try gpa.alloc(?regex.Range, @as(usize, prog.capture_count) + 1);
    errdefer gpa.free(caps);

    var steps: u64 = 1_000_000;
    const matched = try regex.exec(gpa, &prog, inp16, start, &steps, caps);
    if (!matched) {
        gpa.free(caps);
        return null;
    }
    return caps;
}

test "d, u, v flags parsing and canonical order" {
    var diag: regex.Diagnostic = .{};
    const p1 = try regex.parseFlagsAscii("dgimsuy", &diag);
    try testing.expect(p1.flags.has_indices);
    try testing.expect(p1.global);
    try testing.expect(p1.flags.ignore_case);
    try testing.expect(p1.flags.multiline);
    try testing.expect(p1.flags.dot_all);
    try testing.expect(p1.flags.unicode);
    try testing.expect(!p1.flags.unicode_sets);
    try testing.expect(p1.flags.sticky);
    try testing.expectEqualStrings("dgimsuy", p1.canonical());

    const p2 = try regex.parseFlagsAscii("yusimgd", &diag);
    try testing.expectEqualStrings("dgimsuy", p2.canonical());

    const p3 = try regex.parseFlagsAscii("vyid", &diag);
    try testing.expect(p3.flags.has_indices);
    try testing.expect(p3.flags.ignore_case);
    try testing.expect(p3.flags.unicode_sets);
    try testing.expect(p3.flags.sticky);
    try testing.expectEqualStrings("divy", p3.canonical());

    try testing.expectError(error.SyntaxError, regex.parseFlagsAscii("dd", &diag));
    try testing.expectError(error.SyntaxError, regex.parseFlagsAscii("uv", &diag));
    try testing.expectError(error.SyntaxError, regex.parseFlagsAscii("vu", &diag));
}

test "\\cA..\\cZ and \\ca..\\cz control escapes" {
    const gpa = testing.allocator;
    // \cA = 0x01, \cZ = 0x1A, \ca = 0x01, \cz = 0x1A
    {
        const caps = (try runRegex("\\cA\\ca\\cZ\\cz", .{}, "\x01\x01\x1a\x1a", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 4 }, caps[0].?);
    }
    {
        const caps = (try runRegex("[\\cA-\\cC]+", .{}, "\x01\x02\x03\x04", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 3 }, caps[0].?);
    }
    try expectUnsupported("\\c0", .{}, "regex_annex_b");
    try expectUnsupported("[\\c_]", .{}, "regex_annex_b");
}

test "Multi-digit backreferences \\10+" {
    const gpa = testing.allocator;
    {
        const caps = (try runRegex("(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)\\10", .{}, "abcdefghijj", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(@as(usize, 11), caps.len);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 11 }, caps[0].?);
        try testing.expectEqual(regex.Range{ .start = 9, .end = 10 }, caps[10].?);
    }
    {
        const caps = (try runRegex("(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)\\10", .{}, "abcdefghijx", 0));
        try testing.expect(caps == null);
    }
    try expectUnsupported("(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)\\11", .{}, "regex_annex_b");
}

test "Named capturing groups and \\k<name> backreferences" {
    const gpa = testing.allocator;
    {
        const caps = (try runRegex("(?<first>a+)-(?<second>\\k<first>)", .{}, "aa-aa", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(@as(usize, 3), caps.len);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 5 }, caps[0].?);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 2 }, caps[1].?);
        try testing.expectEqual(regex.Range{ .start = 3, .end = 5 }, caps[2].?);
    }
    // Forward named backreference (matches empty when unset)
    {
        const caps = (try runRegex("\\k<foo>(?<foo>a)", .{}, "a", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 1 }, caps[0].?);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 1 }, caps[1].?);
    }
    // Program.named_groups, findNamedGroup, clone, and ownedBytes
    {
        const pat16 = try std.unicode.utf8ToUtf16LeAlloc(gpa, "(a)(?<mid_1>b)(?<$end>c)");
        defer gpa.free(pat16);
        var diag: regex.Diagnostic = .{};
        var prog = try regex.compile(gpa, pat16, .{}, &diag);
        defer prog.deinit(gpa);

        try testing.expectEqual(@as(u16, 3), prog.capture_count);
        try testing.expectEqual(@as(usize, 2), prog.named_groups.len);
        const mid16 = [_]u16{ 'm', 'i', 'd', '_', '1' };
        const end16 = [_]u16{ '$', 'e', 'n', 'd' };
        try testing.expectEqual(@as(?u16, 2), prog.findNamedGroup(&mid16));
        try testing.expectEqual(@as(?u16, 3), prog.findNamedGroup(&end16));

        var cloned = try prog.clone(gpa);
        defer cloned.deinit(gpa);
        try testing.expectEqual(prog.ownedBytes(), cloned.ownedBytes());
        try testing.expectEqual(@as(?u16, 2), cloned.findNamedGroup(&mid16));
    }

    // Syntax errors for invalid/duplicate/unknown named groups
    try expectSyntaxError("(?<>a)");
    try expectSyntaxError("(?<1abc>a)");
    try expectSyntaxError("(?<a-b>a)");
    try expectSyntaxError("(?<a");
    try expectSyntaxError("(?<a>x)(?<a>y)");
    try expectSyntaxError("(?<a>x)\\k<b>");
    try expectSyntaxError("(?<a>x)\\k");
    try expectSyntaxError("(?<a>x)\\k<a");
    try expectSyntaxError("(?<a>x)[\\k<a>]");

    // Without any named groups, \k is Annex B
    try expectUnsupported("\\k<foo>", .{}, "regex_annex_b");
    try expectUnsupported("[\\k<foo>]", .{}, "regex_annex_b");
}

test "Lookbehind assertions (?<=...) and (?<!...)" {
    const gpa = testing.allocator;
    // Basic positive & negative lookbehind
    {
        const caps = (try runRegex("(?<=a)b", .{}, "xbab", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 3, .end = 4 }, caps[0].?);
    }
    {
        const caps = (try runRegex("(?<!a)b", .{}, "abcb", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 3, .end = 4 }, caps[0].?);
    }
    // Alternation inside lookbehind
    {
        const caps = (try runRegex("(?<=ab|cd)x", .{}, "cdx", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 2, .end = 3 }, caps[0].?);
    }
    // Quantifiers and captures inside lookbehind (captures in left-to-right order)
    {
        const caps = (try runRegex("(?<=(a+)(b+))c", .{}, "aaabbc", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 5, .end = 6 }, caps[0].?);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 3 }, caps[1].?);
        try testing.expectEqual(regex.Range{ .start = 3, .end = 5 }, caps[2].?);
    }
    // Backtracking inside lookbehind (greedy vs lazy)
    {
        const caps = (try runRegex("(?<=a(.*))c", .{}, "axxxc", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 4, .end = 5 }, caps[0].?);
        try testing.expectEqual(regex.Range{ .start = 1, .end = 4 }, caps[1].?);
    }
    {
        const caps = (try runRegex("(?<=a(.*?))c", .{}, "axaxc", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 4, .end = 5 }, caps[0].?);
        try testing.expectEqual(regex.Range{ .start = 3, .end = 4 }, caps[1].?);
    }
    // Nested lookahead inside lookbehind, and lookbehind inside lookbehind
    {
        const caps = (try runRegex("(?<=a(?=b))b", .{}, "ab", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 1, .end = 2 }, caps[0].?);
    }
    {
        const caps = (try runRegex("(?<=(?<=a)b)c", .{}, "abc", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 2, .end = 3 }, caps[0].?);
    }
    // Backreference inside lookbehind (evaluates right-to-left)
    {
        const caps = (try runRegex("(?<=(a)\\1)b", .{}, "aab", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 2, .end = 3 }, caps[0].?);
        try testing.expectEqual(regex.Range{ .start = 1, .end = 2 }, caps[1].?);
    }
    {
        const caps = (try runRegex("(?<=\\1(a))b", .{}, "aab", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 2, .end = 3 }, caps[0].?);
        try testing.expectEqual(regex.Range{ .start = 1, .end = 2 }, caps[1].?);
    }
    // Quantifier on lookbehind is Annex B
    try expectUnsupported("(?<=a)*", .{}, "regex_annex_b");
    try expectUnsupported("(?<!a)+", .{}, "regex_annex_b");
}

test "Inline flag modifiers (?ims-ims:...)" {
    const gpa = testing.allocator;
    // Scoped ignore_case on/off
    {
        const caps = (try runRegex("(?i:a)b", .{}, "Ab", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 2 }, caps[0].?);
    }
    try testing.expect((try runRegex("(?i:a)b", .{}, "AB", 0)) == null);
    try testing.expect((try runRegex("(?-i:a)b", .{ .ignore_case = true }, "Ab", 0)) == null);
    {
        const caps = (try runRegex("(?-i:a)b", .{ .ignore_case = true }, "aB", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 2 }, caps[0].?);
    }
    // Scoped ignore_case on character class and backreference
    {
        const caps = (try runRegex("(?i:[a])(?-i:[a])", .{}, "Aa", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 2 }, caps[0].?);
    }
    try testing.expect((try runRegex("(?i:[a])(?-i:[a])", .{ .ignore_case = true }, "AA", 0)) == null);
    {
        const caps = (try runRegex("(a)(?i:\\1)", .{}, "aA", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 2 }, caps[0].?);
    }
    try testing.expect((try runRegex("(a)(?-i:\\1)", .{ .ignore_case = true }, "aA", 0)) == null);

    // Scoped multiline and dotAll
    {
        const caps = (try runRegex("(?m:^b)", .{}, "a\nb", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 2, .end = 3 }, caps[0].?);
    }
    try testing.expect((try runRegex("(?-m:^b)", .{ .multiline = true }, "a\nb", 0)) == null);
    {
        const caps = (try runRegex("(?s:a.b)", .{}, "a\nb", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 3 }, caps[0].?);
    }
    try testing.expect((try runRegex("(?-s:a.b)", .{ .dot_all = true }, "a\nb", 0)) == null);

    // Nested modifiers & trailing '-'
    {
        const caps = (try runRegex("(?i:a(?-i:b)c)", .{}, "AbC", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 3 }, caps[0].?);
    }
    {
        const caps = (try runRegex("(?i-:a)", .{}, "A", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 1 }, caps[0].?);
    }

    // Invalid modifier syntax
    try expectSyntaxError("(?-:a)");
    try expectSyntaxError("(?ii:a)");
    try expectSyntaxError("(?i-i:a)");
    try expectSyntaxError("(?-ii:a)");
    try expectSyntaxError("(?i-m-s:a)");
    try expectSyntaxError("(?g:a)");
    try expectSyntaxError("(?i)");
    try expectSyntaxError("(?i");
}

test "FailingAllocator sweep for named groups, lookbehind, and modifiers" {
    const scenarios = [_]struct { pat: []const u8, inp: []const u8, flags: regex.Flags }{
        .{ .pat = "(?<w>\\w+)(?<=a+)(?i:\\k<w>)", .inp = "aaAA", .flags = .{} },
        .{ .pat = "(?<!x)(?<=a(b+)c)d", .inp = "abbbcd", .flags = .{} },
    };
    for (scenarios) |s| {
        try testing.checkAllAllocationFailures(
            testing.allocator,
            compileAndExecOnce,
            .{ s.pat, s.inp, s.flags },
        );
    }
}

test "Non-ASCII /i case folding: legacy (/i) vs Unicode (/iu)" {
    const gpa = testing.allocator;
    // é / É folds in both /i and /iu
    {
        const caps = (try runRegex("é", .{ .ignore_case = true }, "É", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 1 }, caps[0].?);
    }
    {
        const caps = (try runRegex("[é]", .{ .ignore_case = true, .unicode = true }, "É", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 1 }, caps[0].?);
    }
    // ſ (U+017F) and K (U+212A): match 's'/'k' in /iu, NOT in legacy /i
    try testing.expect((try runRegex("\\u017F", .{ .ignore_case = true }, "s", 0)) == null);
    try testing.expect((try runRegex("\\u212A", .{ .ignore_case = true }, "k", 0)) == null);
    {
        const caps = (try runRegex("\\u017F\\u212A", .{ .ignore_case = true, .unicode = true }, "SK", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 2 }, caps[0].?);
    }
    // Astral case folding: Deseret U+10400 <-> U+10428 in /iu
    {
        const caps = (try runRegex("(\\u{10400})\\1", .{ .ignore_case = true, .unicode = true }, "\u{10400}\u{10428}", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 4 }, caps[0].?);
    }
    // Non-ASCII class range [À-Þ] matching 'à' in /iu
    {
        const caps = (try runRegex("[\\u00C0-\\u00DE]", .{ .ignore_case = true, .unicode = true }, "à", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 1 }, caps[0].?);
    }
}

test "Unicode mode (/u): surrogate pairs, \\u{...}, \\p{...}, lookbehind, strict syntax" {
    const gpa = testing.allocator;
    // Surrogate pair in pattern and input: '.' matches 1 code point (2 UTF-16 code units)
    {
        const caps = (try runRegex("^.$", .{ .unicode = true }, "😀", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 2 }, caps[0].?);
    }
    {
        const caps = (try runRegex("\\u{1F600}\\uD83D\\uDE00", .{ .unicode = true }, "😀😀", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 4 }, caps[0].?);
    }
    // Lookbehind with surrogate pairs
    {
        const caps = (try runRegex("(?<=😀)a", .{ .unicode = true }, "😀a", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 2, .end = 3 }, caps[0].?);
    }
    // \p{...} and \P{...}
    {
        const caps = (try runRegex("^\\p{Script=Greek}+\\P{ASCII}$", .{ .unicode = true }, "αβγ😀", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 5 }, caps[0].?);
    }
    {
        const caps = (try runRegex("^\\p{Emoji}$", .{ .unicode = true }, "😀", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 2 }, caps[0].?);
    }
    // Invalid \u{...}, \p{...}, and strict u-mode syntax (no Annex B)
    try expectSyntaxErrorWithFlags("\\u{}", .{ .unicode = true });
    try expectSyntaxErrorWithFlags("\\u{110000}", .{ .unicode = true });
    try expectSyntaxErrorWithFlags("\\u{xyz}", .{ .unicode = true });
    try expectSyntaxErrorWithFlags("\\p{NoSuchProp}", .{ .unicode = true });
    try expectSyntaxErrorWithFlags("\\a", .{ .unicode = true });
    try expectSyntaxErrorWithFlags("\\8", .{ .unicode = true });
    try expectSyntaxErrorWithFlags("{", .{ .unicode = true });
    try expectSyntaxErrorWithFlags("}", .{ .unicode = true });
    try expectSyntaxErrorWithFlags("]", .{ .unicode = true });
    try expectSyntaxErrorWithFlags("(?=a)*", .{ .unicode = true });
    try expectSyntaxErrorWithFlags("[\\d-a]", .{ .unicode = true });
    try expectSyntaxErrorWithFlags("\\c_", .{ .unicode = true });
}

test "UnicodeSets mode (/v): nested classes, &&, --, \\q{...}, \\p{Basic_Emoji}" {
    const gpa = testing.allocator;
    // Intersection && and subtraction --
    {
        const caps = (try runRegex("[\\p{ASCII}&&\\d]+", .{ .unicode_sets = true }, "123abc", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 3 }, caps[0].?);
    }
    {
        const caps = (try runRegex("[[a-z]--[aeiou]]+", .{ .unicode_sets = true }, "bcd", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 3 }, caps[0].?);
    }
    try testing.expect((try runRegex("[[a-z]--[aeiou]]", .{ .unicode_sets = true }, "a", 0)) == null);

    // v-mode /vi subtraction with case folding: [[A-Z]--[a]] excludes both 'A' and 'a'
    try testing.expect((try runRegex("[[A-Z]--[a]]", .{ .unicode_sets = true, .ignore_case = true }, "A", 0)) == null);
    try testing.expect((try runRegex("[[A-Z]--[a]]", .{ .unicode_sets = true, .ignore_case = true }, "a", 0)) == null);
    {
        const caps = (try runRegex("[[A-Z]--[a]]", .{ .unicode_sets = true, .ignore_case = true }, "b", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 1 }, caps[0].?);
    }

    // String disjunction \q{...} with longest-first matching and backtracking
    {
        const caps = (try runRegex("[\\q{ab|a}]b", .{ .unicode_sets = true }, "ab", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 2 }, caps[0].?);
    }
    {
        const caps = (try runRegex("^[\\q{abc|def|}]$", .{ .unicode_sets = true }, "", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 0 }, caps[0].?);
    }

    // \p{Basic_Emoji} (property of strings)
    {
        const caps = (try runRegex("^\\p{Basic_Emoji}$", .{ .unicode_sets = true }, "😀", 0)).?;
        defer gpa.free(caps);
        try testing.expectEqual(regex.Range{ .start = 0, .end = 2 }, caps[0].?);
    }

    // v-mode syntax errors
    try expectSyntaxErrorWithFlags("[^\\q{ab}]", .{ .unicode_sets = true });
    try expectSyntaxErrorWithFlags("[^\\p{Basic_Emoji}]", .{ .unicode_sets = true });
    try expectSyntaxErrorWithFlags("\\P{Basic_Emoji}", .{ .unicode_sets = true });
    try expectSyntaxErrorWithFlags("[a&&b--c]", .{ .unicode_sets = true });
    try expectSyntaxErrorWithFlags("[ab&&c]", .{ .unicode_sets = true });
    try expectSyntaxErrorWithFlags("[a-]", .{ .unicode_sets = true });
    try expectSyntaxErrorWithFlags("[(]", .{ .unicode_sets = true });
    try expectSyntaxErrorWithFlags("[!!]", .{ .unicode_sets = true });
    try expectSyntaxErrorWithFlags("[$$]", .{ .unicode_sets = true });
}

test "FailingAllocator sweep for /u and /v modes" {
    const scenarios = [_]struct { pat: []const u8, inp: []const u8, flags: regex.Flags }{
        .{ .pat = "(?<=😀)[\\p{ASCII}&&\\w]+", .inp = "😀abc", .flags = .{ .unicode_sets = true } },
        .{ .pat = "[\\q{ab|a}]+", .inp = "aba", .flags = .{ .unicode_sets = true } },
    };
    for (scenarios) |s| {
        try testing.checkAllAllocationFailures(
            testing.allocator,
            compileAndExecOnce,
            .{ s.pat, s.inp, s.flags },
        );
    }
}
