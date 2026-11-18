//! Unit tests and node-generated fixture tests (`tests/regex/cases.jsonl`) for `src/regex.zig`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const regex = @import("regex");
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

test "Unsupported features return stable diag.feature ids" {
    // Non-ASCII literal or class range with ignore_case flag
    try expectUnsupported("é", .{ .ignore_case = true }, "regex_ignore_case_unicode");
    try expectUnsupported("\\u00e9", .{ .ignore_case = true }, "regex_ignore_case_unicode");
    try expectUnsupported("[a-\\u0100]", .{ .ignore_case = true }, "regex_ignore_case_unicode");
    try expectUnsupported("[\\u0080]", .{ .ignore_case = true }, "regex_ignore_case_unicode");

    // Named groups and named backreferences
    try expectUnsupported("(?<foo>a)", .{}, "regex_named_groups");
    try expectUnsupported("\\k<foo>", .{}, "regex_named_groups");
    try expectUnsupported("[\\k<foo>]", .{}, "regex_named_groups");

    // Lookbehind
    try expectUnsupported("(?<=a)b", .{}, "regex_lookbehind");
    try expectUnsupported("(?<!a)b", .{}, "regex_lookbehind");

    // Unicode property escapes
    try expectUnsupported("\\p{ASCII}", .{}, "regex_unicode_property");
    try expectUnsupported("\\P{Letter}", .{}, "regex_unicode_property");
    try expectUnsupported("[\\p{ASCII}]", .{}, "regex_unicode_property");
    try expectUnsupported("[\\P{ASCII}]", .{}, "regex_unicode_property");

    // Braced unicode escapes and control escapes
    try expectUnsupported("\\u{1234}", .{}, "regex_unicode_escape_braced");
    try expectUnsupported("[\\u{41}]", .{}, "regex_unicode_escape_braced");
    try expectUnsupported("\\cA", .{}, "regex_control_escape");
    try expectUnsupported("[\\cA]", .{}, "regex_control_escape");

    // Inline modifier groups
    try expectUnsupported("(?i:a)", .{}, "regex_modifiers");
    try expectUnsupported("(?-i:a)", .{}, "regex_modifiers");
    try expectUnsupported("(?m:a)", .{}, "regex_modifiers");
    try expectUnsupported("(?s:a)", .{}, "regex_modifiers");

    // Backreferences > \9 when that many captures exist
    try expectUnsupported("(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)\\10", .{}, "regex_backref_gt9");

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
    try expectUnsupported("{", .{}, "regex_annex_b");
    try expectUnsupported("}", .{}, "regex_annex_b");
    try expectUnsupported("a{1,x}", .{}, "regex_annex_b");
    try expectUnsupported("]", .{}, "regex_annex_b");
    try expectUnsupported("[\\d-a]", .{}, "regex_annex_b");
    try expectUnsupported("[a-\\d]", .{}, "regex_annex_b");
    try expectUnsupported("(?=a)*", .{}, "regex_annex_b");
    try expectUnsupported("(?!a)+", .{}, "regex_annex_b");
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
