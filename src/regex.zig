//! Standalone ECMAScript-style regular expression engine over UTF-16 code units.
//!
//! No native recursion in either the parser/compiler or the backtracking matcher:
//! compilation uses an explicit operator/group stack bounded by `max_depth`, and
//! execution uses an explicit heap stack bounded by the caller's step budget.

const std = @import("std");
const Allocator = std.mem.Allocator;
const limits = @import("limits.zig");
const Limit = limits.Limit;
const unicode = @import("regex_unicode.zig");

/// Maximum group/lookahead nesting depth during parsing. Prevents pathological patterns
/// from consuming excessive compile-time stack memory and satisfies the spec requirement.
pub const max_depth: u16 = limits.regex_max_depth;

/// Maximum number of compiled bytecode instructions in a single regex `Program`.
/// Quantifiers with finite bounds (`{n,m}`) are compiled using counted loop registers
/// rather than unrolling, so legitimate patterns stay well below this bound while huge
/// patterns fail cleanly with `error.TooComplex` instead of exhausting heap memory.
pub const max_program_insts: u32 = limits.regex_max_program_insts;

/// Maximum number of character-class range items across all `[...]` classes in a program.
/// Prevents a single pattern with thousands of ranges from growing unboundedly.
pub const max_class_items: u32 = limits.regex_max_class_items;

/// Maximum number of loop counters (`{n,m}` / `*` / `+` / `?` repetitions) in a program.
pub const max_loops: u16 = limits.regex_max_loops;

/// Maximum number of capturing groups in a single pattern.
pub const max_captures: u16 = limits.regex_max_captures;

/// Maximum quantifier repetition bound (`{n,m}`). Exceeding this returns `error.TooComplex`.
pub const max_quantifier_bound: u32 = limits.regex_max_quantifier_bound;

/// Index ceilings for the matcher's backtrack stack, not policy limits: a greedy loop
/// saves one state per iteration, so a small cap would reject `.*` over long input.
/// The caller's `steps` budget and allocator bound the real work and memory.
pub const max_backtrack_states: u32 = limits.regex_max_backtrack_states;
pub const max_backtrack_cells: u32 = limits.regex_max_backtrack_cells;

pub const Flags = struct {
    has_indices: bool = false,
    ignore_case: bool = false,
    multiline: bool = false,
    dot_all: bool = false,
    unicode: bool = false,
    unicode_sets: bool = false,
    sticky: bool = false,

    pub fn isUnicodeMode(self: Flags) bool {
        return self.unicode or self.unicode_sets;
    }
};

pub const ParsedFlags = struct {
    flags: Flags = .{},
    global: bool = false,
    canonical_buf: [8]u8 = undefined,
    canonical_len: u8 = 0,

    pub fn canonical(self: *const ParsedFlags) []const u8 {
        return self.canonical_buf[0..self.canonical_len];
    }
};

pub fn parseFlagsUtf16(units: []const u16, diag: *Diagnostic) CompileError!ParsedFlags {
    diag.* = .{};
    var seen_d = false;
    var seen_g = false;
    var seen_i = false;
    var seen_m = false;
    var seen_s = false;
    var seen_u = false;
    var seen_v = false;
    var seen_y = false;

    for (units) |u| {
        const dup = switch (u) {
            'd' => blk: {
                const prev = seen_d;
                seen_d = true;
                break :blk prev;
            },
            'g' => blk: {
                const prev = seen_g;
                seen_g = true;
                break :blk prev;
            },
            'i' => blk: {
                const prev = seen_i;
                seen_i = true;
                break :blk prev;
            },
            'm' => blk: {
                const prev = seen_m;
                seen_m = true;
                break :blk prev;
            },
            's' => blk: {
                const prev = seen_s;
                seen_s = true;
                break :blk prev;
            },
            'u' => blk: {
                const prev = seen_u;
                seen_u = true;
                break :blk prev;
            },
            'v' => blk: {
                const prev = seen_v;
                seen_v = true;
                break :blk prev;
            },
            'y' => blk: {
                const prev = seen_y;
                seen_y = true;
                break :blk prev;
            },
            else => {
                diag.* = .{ .message = "invalid regular expression flag" };
                return error.SyntaxError;
            },
        };
        if (dup) {
            diag.* = .{ .message = "duplicate regular expression flag" };
            return error.SyntaxError;
        }
    }
    if (seen_u and seen_v) {
        diag.* = .{ .message = "incompatible 'u' and 'v' regular expression flags" };
        return error.SyntaxError;
    }

    var out: ParsedFlags = .{
        .flags = .{
            .has_indices = seen_d,
            .ignore_case = seen_i,
            .multiline = seen_m,
            .dot_all = seen_s,
            .unicode = seen_u,
            .unicode_sets = seen_v,
            .sticky = seen_y,
        },
        .global = seen_g,
    };
    if (seen_d) {
        out.canonical_buf[out.canonical_len] = 'd';
        out.canonical_len += 1;
    }
    if (seen_g) {
        out.canonical_buf[out.canonical_len] = 'g';
        out.canonical_len += 1;
    }
    if (seen_i) {
        out.canonical_buf[out.canonical_len] = 'i';
        out.canonical_len += 1;
    }
    if (seen_m) {
        out.canonical_buf[out.canonical_len] = 'm';
        out.canonical_len += 1;
    }
    if (seen_s) {
        out.canonical_buf[out.canonical_len] = 's';
        out.canonical_len += 1;
    }
    if (seen_u) {
        out.canonical_buf[out.canonical_len] = 'u';
        out.canonical_len += 1;
    }
    if (seen_v) {
        out.canonical_buf[out.canonical_len] = 'v';
        out.canonical_len += 1;
    }
    if (seen_y) {
        out.canonical_buf[out.canonical_len] = 'y';
        out.canonical_len += 1;
    }
    return out;
}

pub fn parseFlagsAscii(bytes: []const u8, diag: *Diagnostic) CompileError!ParsedFlags {
    var stack_buf: [16]u16 = undefined;
    if (bytes.len > stack_buf.len) {
        // Any flag string > 8 chars either has a duplicate or an invalid char; scan prefix+offending char.
        for (bytes, 0..) |b, idx| {
            if (idx < stack_buf.len) stack_buf[idx] = b;
        }
        return parseFlagsUtf16(stack_buf[0..stack_buf.len], diag);
    }
    for (bytes, 0..) |b, idx| stack_buf[idx] = b;
    return parseFlagsUtf16(stack_buf[0..bytes.len], diag);
}

/// ECMAScript `EscapeRegExpPattern`: produces the UTF-16 `.source` text for a compiled pattern.
pub fn escapePattern(gpa: Allocator, pattern: []const u16) error{OutOfMemory}![]u16 {
    if (pattern.len == 0) {
        return gpa.dupe(u16, &[_]u16{ '(', '?', ':', ')' });
    }
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, pattern.len);

    var in_class = false;
    var i: usize = 0;
    while (i < pattern.len) {
        const c = pattern[i];
        if (c == '\\' and i + 1 < pattern.len) {
            try out.append(gpa, '\\');
            const next = pattern[i + 1];
            switch (next) {
                0x000A => try out.append(gpa, 'n'),
                0x000D => try out.append(gpa, 'r'),
                0x2028 => try out.appendSlice(gpa, &[_]u16{ 'u', '2', '0', '2', '8' }),
                0x2029 => try out.appendSlice(gpa, &[_]u16{ 'u', '2', '0', '2', '9' }),
                else => try out.append(gpa, next),
            }
            i += 2;
            continue;
        }
        switch (c) {
            '[' => {
                in_class = true;
                try out.append(gpa, '[');
            },
            ']' => {
                in_class = false;
                try out.append(gpa, ']');
            },
            '/' => {
                if (!in_class) try out.append(gpa, '\\');
                try out.append(gpa, '/');
            },
            0x000A => try out.appendSlice(gpa, &[_]u16{ '\\', 'n' }),
            0x000D => try out.appendSlice(gpa, &[_]u16{ '\\', 'r' }),
            0x2028 => try out.appendSlice(gpa, &[_]u16{ '\\', 'u', '2', '0', '2', '8' }),
            0x2029 => try out.appendSlice(gpa, &[_]u16{ '\\', 'u', '2', '0', '2', '9' }),
            else => try out.append(gpa, c),
        }
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

pub const Range = struct {
    start: u32,
    end: u32,
};

pub const CompileError = error{
    SyntaxError,
    Unsupported,
    OutOfMemory,
    TooComplex,
};

pub const Diagnostic = struct {
    message: []const u8 = "",
    feature: ?[]const u8 = null,
    limit: Limit = .code_bytes,
};

pub const ExecError = error{
    StepLimit,
    OutOfMemory,
};

const BuiltinClass = enum(u8) {
    digit, // \d
    not_digit, // \D
    word, // \w
    not_word, // \W
    space, // \s
    not_space, // \S
};

const ClassOp = enum(u8) {
    union_op,
    intersection_op,
    subtraction_op,
};

const ClassNode = union(enum) {
    range: struct { lo: u21, hi: u21 },
    builtin: BuiltinClass,
    unicode_prop: []const unicode.Range,
    string_prop: []const []const u21,
    string_literal: struct { start: u32, len: u32 },
    compound: struct {
        op: ClassOp,
        inverted: bool,
        ignore_case: bool,
        start: u32,
        len: u32,
    },
};

const ClassDef = struct {
    root_node: u32,
    has_strings: bool,
    max_str_len: u32,
};

const LoopInfo = struct {
    min: u32,
    max: u32, // std.math.maxInt(u32) represents infinity
    greedy: bool,
    cap_start: u16,
    cap_end: u16,
};

const Inst = union(enum) {
    match,
    char: u21,
    char_icase: u21, // stored as canonicalized char/cp
    any, // . (not LineTerminator)
    any_dot_all, // . with dot_all
    bol, // ^
    bol_multiline, // ^ with multiline
    eol, // $
    eol_multiline, // $ with multiline
    word_boundary, // \b
    word_boundary_icase, // \b with unicode + ignore_case
    not_word_boundary, // \B
    not_word_boundary_icase, // \B with unicode + ignore_case
    builtin: struct {
        class: BuiltinClass,
        unicode_icase: bool,
    },
    class: u32, // index into Program.classes
    backref: u16, // 1..capture_count
    backref_icase: u16, // 1..capture_count with ignore_case
    save_start: u16, // capture index
    save_end: u16, // capture index
    jump: u32,
    split: struct {
        first: u32,
        second: u32,
    },
    loop_init: struct {
        loop_id: u16,
        step_pc: u32,
    },
    loop_step: struct {
        loop_id: u16,
        body_pc: u32,
        exit_pc: u32,
    },
    lookahead: struct {
        negative: bool,
        reverse: bool,
        body_pc: u32,
        next_pc: u32,
        cap_start: u16,
        cap_end: u16,
    },
    lookahead_done,
};

pub const NamedGroup = struct {
    name: []const u16,
    capture_index: u16,
};

pub const Program = struct {
    insts: []Inst,
    classes: []ClassDef,
    class_nodes: []ClassNode,
    class_strings: []u21,
    loops: []LoopInfo,
    named_groups: []NamedGroup = &.{},
    capture_count: u16,
    loop_count: u16,
    flags: Flags,

    pub fn deinit(self: *Program, gpa: Allocator) void {
        gpa.free(self.insts);
        gpa.free(self.classes);
        gpa.free(self.class_nodes);
        gpa.free(self.class_strings);
        gpa.free(self.loops);
        for (self.named_groups) |ng| gpa.free(ng.name);
        gpa.free(self.named_groups);
        self.* = undefined;
    }

    pub fn ownedBytes(self: *const Program) usize {
        var total = self.insts.len * @sizeOf(Inst) +
            self.classes.len * @sizeOf(ClassDef) +
            self.class_nodes.len * @sizeOf(ClassNode) +
            self.class_strings.len * @sizeOf(u21) +
            self.loops.len * @sizeOf(LoopInfo) +
            self.named_groups.len * @sizeOf(NamedGroup);
        for (self.named_groups) |ng| {
            total += ng.name.len * @sizeOf(u16);
        }
        return total;
    }

    pub fn clone(self: *const Program, gpa: Allocator) error{OutOfMemory}!Program {
        const insts = try gpa.dupe(Inst, self.insts);
        errdefer gpa.free(insts);
        const classes = try gpa.dupe(ClassDef, self.classes);
        errdefer gpa.free(classes);
        const class_nodes = try gpa.dupe(ClassNode, self.class_nodes);
        errdefer gpa.free(class_nodes);
        const class_strings = try gpa.dupe(u21, self.class_strings);
        errdefer gpa.free(class_strings);
        const loops = try gpa.dupe(LoopInfo, self.loops);
        errdefer gpa.free(loops);
        const named_groups = try gpa.alloc(NamedGroup, self.named_groups.len);
        var cloned_names: usize = 0;
        errdefer {
            for (named_groups[0..cloned_names]) |ng| gpa.free(ng.name);
            gpa.free(named_groups);
        }
        for (self.named_groups, 0..) |ng, idx| {
            named_groups[idx] = .{
                .name = try gpa.dupe(u16, ng.name),
                .capture_index = ng.capture_index,
            };
            cloned_names += 1;
        }
        return .{
            .insts = insts,
            .classes = classes,
            .class_nodes = class_nodes,
            .class_strings = class_strings,
            .loops = loops,
            .named_groups = named_groups,
            .capture_count = self.capture_count,
            .loop_count = self.loop_count,
            .flags = self.flags,
        };
    }

    pub fn findNamedGroup(self: *const Program, name: []const u16) ?u16 {
        for (self.named_groups) |ng| {
            if (std.mem.eql(u16, ng.name, name)) return ng.capture_index;
        }
        return null;
    }
};

fn isAsciiDigit(c: u21) bool {
    return c >= '0' and c <= '9';
}

fn isAsciiWord(c: u21) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

fn isLineTerminator(c: u21) bool {
    return c == 0x000A or c == 0x000D or c == 0x2028 or c == 0x2029;
}

fn isWhiteSpaceOrLineTerminator(c: u21) bool {
    return switch (c) {
        0x0009,
        0x000A,
        0x000B,
        0x000C,
        0x000D,
        0x0020,
        0x00A0,
        0x1680,
        0x2000...0x200A,
        0x2028,
        0x2029,
        0x202F,
        0x205F,
        0x3000,
        0xFEFF,
        => true,
        else => false,
    };
}

fn isWordChar(c: u21, unicode_icase: bool) bool {
    return isAsciiWord(c) or (unicode_icase and (c == 0x017F or c == 0x212A));
}

fn matchesBuiltin(b: BuiltinClass, c: u21, unicode_icase: bool) bool {
    return switch (b) {
        .digit => isAsciiDigit(c),
        .not_digit => !isAsciiDigit(c),
        .word => isWordChar(c, unicode_icase),
        .not_word => !isWordChar(c, unicode_icase),
        .space => isWhiteSpaceOrLineTerminator(c),
        .not_space => !isWhiteSpaceOrLineTerminator(c),
    };
}

fn isLeadSurrogate(cu: u16) bool {
    return cu >= 0xD800 and cu <= 0xDBFF;
}

fn isTrailSurrogate(cu: u16) bool {
    return cu >= 0xDC00 and cu <= 0xDFFF;
}

fn combineSurrogates(lead: u16, trail: u16) u21 {
    return 0x10000 + ((@as(u21, lead - 0xD800) << 10) | @as(u21, trail - 0xDC00));
}

fn hexDigit(c: u16) ?u16 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn isSyntaxCharacter(c: u21) bool {
    return switch (c) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|' => true,
        else => false,
    };
}

fn isClassSetSyntaxChar(c: u21) bool {
    return switch (c) {
        '(', ')', '[', ']', '{', '}', '/', '-', '\\', '|' => true,
        else => false,
    };
}

fn isClassSetReservedPunctuator(c: u21) bool {
    return switch (c) {
        '&', '-', '!', '#', '%', ',', ':', ';', '<', '=', '>', '@', '`', '~' => true,
        else => false,
    };
}

fn isClassSetDoublePunctuatorChar(c: u21) bool {
    return switch (c) {
        '&', '!', '#', '$', '%', '*', '+', ',', '.', ':', ';', '<', '=', '>', '?', '@', '^', '`', '~' => true,
        else => false,
    };
}

fn isGroupNameStartCp(cp: u21) bool {
    if (cp == '$' or cp == '_') return true;
    if ((cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z')) return true;
    if (cp >= 0x80) {
        if (unicode.lookupProperty("ID_Start")) |ranges| return unicode.inRanges(cp, ranges);
    }
    return false;
}

fn isGroupNamePartCp(cp: u21) bool {
    if (isGroupNameStartCp(cp)) return true;
    if ((cp >= '0' and cp <= '9') or cp == 0x200C or cp == 0x200D) return true;
    if (cp >= 0x80) {
        if (unicode.lookupProperty("ID_Continue")) |ranges| return unicode.inRanges(cp, ranges);
    }
    return false;
}

fn hexDigitVal(cu: u16) ?u21 {
    if (cu >= '0' and cu <= '9') return cu - '0';
    if (cu >= 'a' and cu <= 'f') return cu - 'a' + 10;
    if (cu >= 'A' and cu <= 'F') return cu - 'A' + 10;
    return null;
}

const GroupKind = enum {
    capturing,
    non_capturing,
    pos_lookahead,
    neg_lookahead,
    pos_lookbehind,
    neg_lookbehind,

    fn isAssertion(self: GroupKind) bool {
        return switch (self) {
            .pos_lookahead, .neg_lookahead, .pos_lookbehind, .neg_lookbehind => true,
            else => false,
        };
    }
};

const GroupFrame = struct {
    kind: GroupKind,
    capture_index: u16,
    cap_before: u16,
    term_start_pc: u32,
    branch_start_pc: u32,
    saved_flags: Flags,
    saved_in_lookbehind: bool,
    /// Fixup list of `jump` instructions at the end of finished branches in this group.
    end_jumps: std.ArrayList(u32) = .empty,
    /// PC of the `lookahead` instruction if `kind` is an assertion.
    lookahead_pc: u32 = 0,
};

const LastAtom = struct {
    start_pc: u32,
    end_pc: u32,
    cap_start: u16,
    cap_end: u16,
    quantifiable: bool,
    is_lookahead: bool,
};

const Compiler = struct {
    gpa: Allocator,
    pattern: []const u16,
    pos: usize = 0,
    flags: Flags,
    in_lookbehind: bool = false,
    max_depth: u16 = max_depth,
    diag: *Diagnostic,
    total_captures: u16 = 0,
    next_capture: u16 = 0,

    insts: std.ArrayList(Inst) = .empty,
    classes: std.ArrayList(ClassDef) = .empty,
    class_nodes: std.ArrayList(ClassNode) = .empty,
    class_strings: std.ArrayList(u21) = .empty,
    loops: std.ArrayList(LoopInfo) = .empty,
    groups: std.ArrayList(GroupFrame) = .empty,
    named_groups: std.ArrayList(NamedGroup) = .empty,

    /// Top-level current alternative start PC and end-of-branch `jump` fixups.
    top_branch_start_pc: u32 = 0,
    top_end_jumps: std.ArrayList(u32) = .empty,
    last_atom: ?LastAtom = null,

    fn deinit(self: *Compiler) void {
        for (self.groups.items) |*g| g.end_jumps.deinit(self.gpa);
        self.groups.deinit(self.gpa);
        self.top_end_jumps.deinit(self.gpa);
        self.insts.deinit(self.gpa);
        self.classes.deinit(self.gpa);
        self.class_nodes.deinit(self.gpa);
        self.class_strings.deinit(self.gpa);
        self.loops.deinit(self.gpa);
        for (self.named_groups.items) |ng| self.gpa.free(ng.name);
        self.named_groups.deinit(self.gpa);
    }

    fn failAnnexB(self: *Compiler, msg: []const u8) CompileError {
        if (self.flags.isUnicodeMode()) {
            return self.failSyntax(msg);
        }
        return self.failUnsupported("regex_annex_b", msg);
    }

    fn failSyntax(self: *Compiler, msg: []const u8) CompileError {
        self.diag.* = .{ .message = msg, .feature = null };
        return error.SyntaxError;
    }

    fn failUnsupported(self: *Compiler, feature: []const u8, msg: []const u8) CompileError {
        self.diag.* = .{ .message = msg, .feature = feature };
        return error.Unsupported;
    }

    fn failComplex(self: *Compiler, msg: []const u8) CompileError {
        self.diag.* = .{ .message = msg, .feature = null, .limit = .code_bytes };
        return error.TooComplex;
    }

    fn failDepth(self: *Compiler, msg: []const u8) CompileError {
        self.diag.* = .{ .message = msg, .feature = null, .limit = .nesting_depth };
        return error.TooComplex;
    }

    fn emit(self: *Compiler, inst: Inst) CompileError!u32 {
        if (self.insts.items.len >= max_program_insts) {
            return self.failComplex("regex program exceeds instruction limit");
        }
        const pc: u32 = @intCast(self.insts.items.len);
        try self.insts.append(self.gpa, inst);
        return pc;
    }

    fn insertInstAt(self: *Compiler, at: u32, inst: Inst) CompileError!void {
        if (self.insts.items.len >= max_program_insts) {
            return self.failComplex("regex program exceeds instruction limit");
        }
        try self.insts.insert(self.gpa, at, inst);
        // Relocate internal PC targets inside `[at + 1 ..]` that point at or after `at`.
        for (self.insts.items[at + 1 ..]) |*item| {
            switch (item.*) {
                .jump => |*t| if (t.* >= at) {
                    t.* += 1;
                },
                .split => |*s| {
                    if (s.first >= at) s.first += 1;
                    if (s.second >= at) s.second += 1;
                },
                .loop_init => |*l| if (l.step_pc >= at) {
                    l.step_pc += 1;
                },
                .loop_step => |*l| {
                    if (l.body_pc >= at) l.body_pc += 1;
                    if (l.exit_pc >= at) l.exit_pc += 1;
                },
                .lookahead => |*la| {
                    if (la.body_pc >= at) la.body_pc += 1;
                    if (la.next_pc >= at) la.next_pc += 1;
                },
                else => {},
            }
        }
        for (self.top_end_jumps.items) |*j| {
            if (j.* >= at) j.* += 1;
        }
        if (self.top_branch_start_pc > at) self.top_branch_start_pc += 1;
        for (self.groups.items) |*g| {
            for (g.end_jumps.items) |*j| {
                if (j.* >= at) j.* += 1;
            }
            if (g.term_start_pc > at) g.term_start_pc += 1;
            if (g.branch_start_pc > at) g.branch_start_pc += 1;
            if (g.lookahead_pc >= at and g.kind.isAssertion()) {
                g.lookahead_pc += 1;
            }
        }
    }

    fn shiftInstTargets(item: *Inst, delta: i64) void {
        const shift = struct {
            fn apply(pc: *u32, d: i64) void {
                pc.* = @intCast(@as(i64, pc.*) + d);
            }
        }.apply;
        switch (item.*) {
            .jump => |*t| shift(t, delta),
            .split => |*s| {
                shift(&s.first, delta);
                shift(&s.second, delta);
            },
            .loop_init => |*l| shift(&l.step_pc, delta),
            .loop_step => |*l| {
                shift(&l.body_pc, delta);
                shift(&l.exit_pc, delta);
            },
            .lookahead => |*la| {
                shift(&la.body_pc, delta);
                shift(&la.next_pc, delta);
            },
            else => {},
        }
    }

    /// Move `[src_start .. src_end)` to `dst` (`dst <= src_start <= src_end`),
    /// relocating internal PC targets within `[dst .. src_end)`.
    fn moveInstRange(self: *Compiler, dst: u32, src_start: u32, src_end: u32) void {
        if (dst == src_start or src_start == src_end) return;
        const len: u32 = src_end - src_start;
        const gap: u32 = src_start - dst;
        std.mem.rotate(Inst, self.insts.items[dst..src_end], gap);
        for (self.insts.items[dst .. dst + len]) |*item| {
            shiftInstTargets(item, -@as(i64, gap));
        }
        for (self.insts.items[dst + len .. src_end]) |*item| {
            shiftInstTargets(item, @as(i64, len));
        }
    }

    fn currentBranchStartPc(self: *const Compiler) u32 {
        if (self.groups.items.len > 0) {
            return self.groups.items[self.groups.items.len - 1].branch_start_pc;
        }
        return self.top_branch_start_pc;
    }

    fn emitAtomInst(self: *Compiler, inst: Inst) CompileError!u32 {
        if (self.in_lookbehind) {
            const at = self.currentBranchStartPc();
            try self.insertInstAt(at, inst);
            return at;
        }
        return self.emit(inst);
    }

    fn findNamedGroup(self: *const Compiler, name: []const u16) ?u16 {
        for (self.named_groups.items) |ng| {
            if (std.mem.eql(u16, ng.name, name)) return ng.capture_index;
        }
        return null;
    }

    fn parseGroupNameUnit(self: *Compiler, idx: *usize) CompileError!u21 {
        const p = self.pattern;
        if (idx.* >= p.len) return self.failSyntax("unterminated capture group name");
        if (p[idx.*] == '\\') {
            if (idx.* + 1 >= p.len or p[idx.* + 1] != 'u') return self.failSyntax("invalid capture group name");
            idx.* += 2;
            if (idx.* < p.len and p[idx.*] == '{') {
                idx.* += 1;
                var cp: u21 = 0;
                var digits: usize = 0;
                while (idx.* < p.len and p[idx.*] != '}') : (idx.* += 1) {
                    const d = hexDigitVal(p[idx.*]) orelse return self.failSyntax("invalid capture group name");
                    cp = cp * 16 + d;
                    if (cp > 0x10FFFF) return self.failSyntax("invalid capture group name");
                    digits += 1;
                }
                if (digits == 0 or idx.* >= p.len or p[idx.*] != '}') return self.failSyntax("invalid capture group name");
                idx.* += 1;
                return cp;
            }
            if (idx.* + 4 > p.len) return self.failSyntax("invalid capture group name");
            var cu: u21 = 0;
            for (0..4) |k| {
                const d = hexDigitVal(p[idx.* + k]) orelse return self.failSyntax("invalid capture group name");
                cu = cu * 16 + d;
            }
            idx.* += 4;
            if (cu >= 0xD800 and cu <= 0xDBFF and idx.* + 6 <= p.len and p[idx.*] == '\\' and p[idx.* + 1] == 'u' and p[idx.* + 2] != '{') {
                var lo: u21 = 0;
                var ok = true;
                for (0..4) |k| {
                    if (hexDigitVal(p[idx.* + 2 + k])) |d| {
                        lo = lo * 16 + d;
                    } else {
                        ok = false;
                        break;
                    }
                }
                if (ok and lo >= 0xDC00 and lo <= 0xDFFF) {
                    idx.* += 6;
                    return 0x10000 + ((cu - 0xD800) << 10) + (lo - 0xDC00);
                }
            }
            return cu;
        }
        const cu = p[idx.*];
        idx.* += 1;
        if (cu >= 0xD800 and cu <= 0xDBFF and idx.* < p.len) {
            const lo = p[idx.*];
            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                idx.* += 1;
                return 0x10000 + ((@as(u21, cu) - 0xD800) << 10) + (@as(u21, lo) - 0xDC00);
            }
        }
        return cu;
    }

    fn parseGroupNameAt(self: *Compiler, start_pos: usize) CompileError!struct { name: []u16, next_pos: usize } {
        var j = start_pos;
        if (j >= self.pattern.len) return self.failSyntax("unterminated capture group name");
        if (self.pattern[j] == '>') return self.failSyntax("invalid capture group name");

        var buf: std.ArrayList(u16) = .empty;
        errdefer buf.deinit(self.gpa);

        var first = true;
        while (j < self.pattern.len and self.pattern[j] != '>') {
            const cp = try self.parseGroupNameUnit(&j);
            if (first) {
                if (!isGroupNameStartCp(cp)) return self.failSyntax("invalid capture group name");
                first = false;
            } else {
                if (!isGroupNamePartCp(cp)) return self.failSyntax("invalid capture group name");
            }
            if (cp <= 0xFFFF) {
                try buf.append(self.gpa, @intCast(cp));
            } else {
                const adj = cp - 0x10000;
                try buf.append(self.gpa, @intCast(0xD800 + (adj >> 10)));
                try buf.append(self.gpa, @intCast(0xDC00 + (adj & 0x3FF)));
            }
        }
        if (j >= self.pattern.len) return self.failSyntax("unterminated capture group name");
        return .{ .name = try buf.toOwnedSlice(self.gpa), .next_pos = j + 1 };
    }

    /// Pre-pass to count capturing groups and register named groups so `\N` and `\k<name>`
    /// (including forward references) can be validated before emitting instructions.
    fn countCapturesPrepass(self: *Compiler) CompileError!u16 {
        var count: u32 = 0;
        var i: usize = 0;
        var in_class = false;
        while (i < self.pattern.len) {
            const c = self.pattern[i];
            if (c == '\\') {
                i += 1;
                if (i < self.pattern.len) i += 1;
                continue;
            }
            if (in_class) {
                if (c == ']') in_class = false;
                i += 1;
                continue;
            }
            if (c == '[') {
                in_class = true;
                i += 1;
                continue;
            }
            if (c == '(') {
                if (i + 1 < self.pattern.len and self.pattern[i + 1] == '?') {
                    if (i + 2 < self.pattern.len and self.pattern[i + 2] == '<') {
                        if (i + 3 >= self.pattern.len) {
                            return self.failSyntax("unterminated group");
                        }
                        if (self.pattern[i + 3] != '=' and self.pattern[i + 3] != '!') {
                            count += 1;
                            if (count > max_captures) return self.failComplex("too many capturing groups");
                            const parsed = try self.parseGroupNameAt(i + 3);
                            errdefer self.gpa.free(parsed.name);
                            if (self.findNamedGroup(parsed.name) != null) {
                                return self.failSyntax("duplicate capture group name");
                            }
                            try self.named_groups.append(self.gpa, .{
                                .name = parsed.name,
                                .capture_index = @intCast(count),
                            });
                            i = parsed.next_pos;
                            continue;
                        }
                    }
                } else {
                    count += 1;
                    if (count > max_captures) return self.failComplex("too many capturing groups");
                }
            }
            i += 1;
        }
        return @intCast(count);
    }

    fn emitLiteral(self: *Compiler, c: u21) CompileError!void {
        const inst: Inst = if (self.flags.ignore_case) blk: {
            const canon: u21 = if (self.flags.isUnicodeMode())
                unicode.canonicalizeUnicode(c)
            else
                unicode.canonicalizeLegacy(@intCast(c));
            break :blk .{ .char_icase = canon };
        } else .{ .char = c };
        const start_pc = try self.emitAtomInst(inst);
        self.last_atom = .{
            .start_pc = start_pc,
            .end_pc = start_pc + 1,
            .cap_start = self.next_capture + 1,
            .cap_end = self.next_capture,
            .quantifiable = true,
            .is_lookahead = false,
        };
    }

    fn parseHexEscape(self: *Compiler, digits: usize) CompileError!u16 {
        if (self.pos + digits > self.pattern.len) {
            return self.failAnnexB("malformed hex or unicode escape");
        }
        var val: u16 = 0;
        for (0..digits) |k| {
            const d = hexDigit(self.pattern[self.pos + k]) orelse
                return self.failAnnexB("malformed hex or unicode escape");
            val = (val << 4) | d;
        }
        self.pos += digits;
        return val;
    }

    fn parseBracedHexEscape(self: *Compiler) CompileError!u21 {
        if (!self.flags.isUnicodeMode()) {
            return self.failUnsupported("regex_unicode_escape_braced", "\\u{...} escape requires unicode mode");
        }
        self.pos += 1; // consume '{'
        if (self.pos >= self.pattern.len) return self.failSyntax("unterminated \\u{...} escape");
        var val: u32 = 0;
        var count: usize = 0;
        while (self.pos < self.pattern.len and self.pattern[self.pos] != '}') : (self.pos += 1) {
            const d = hexDigit(self.pattern[self.pos]) orelse return self.failSyntax("invalid hex digit in \\u{...}");
            val = (val << 4) | d;
            if (val > 0x10FFFF) return self.failSyntax("unicode code point out of range");
            count += 1;
        }
        if (count == 0 or self.pos >= self.pattern.len or self.pattern[self.pos] != '}') {
            return self.failSyntax("invalid \\u{...} escape");
        }
        self.pos += 1; // consume '}'
        return @intCast(val);
    }

    fn parseUnicodeEscapeCp(self: *Compiler) CompileError!u21 {
        if (self.pos < self.pattern.len and self.pattern[self.pos] == '{') {
            return self.parseBracedHexEscape();
        }
        const cu = try self.parseHexEscape(4);
        if (self.flags.isUnicodeMode() and isLeadSurrogate(cu) and
            self.pos + 6 <= self.pattern.len and
            self.pattern[self.pos] == '\\' and
            self.pattern[self.pos + 1] == 'u' and
            self.pattern[self.pos + 2] != '{')
        {
            var valid = true;
            var trail: u16 = 0;
            for (0..4) |k| {
                if (hexDigit(self.pattern[self.pos + 2 + k])) |d| {
                    trail = (trail << 4) | d;
                } else {
                    valid = false;
                    break;
                }
            }
            if (valid and isTrailSurrogate(trail)) {
                self.pos += 6;
                return combineSurrogates(cu, trail);
            }
        }
        return cu;
    }

    const ParsedProperty = union(enum) {
        code_points: []const unicode.Range,
        strings: []const []const u21,
    };

    fn parseUnicodeProperty(self: *Compiler, negated: bool) CompileError!ParsedProperty {
        if (!self.flags.isUnicodeMode()) {
            return self.failUnsupported("regex_unicode_property", "unicode property escapes are not supported");
        }
        if (self.pos >= self.pattern.len or self.pattern[self.pos] != '{') {
            return self.failSyntax("expected '{' after \\p or \\P");
        }
        self.pos += 1;
        var buf: [64]u8 = undefined;
        var len: usize = 0;
        while (self.pos < self.pattern.len and self.pattern[self.pos] != '}') : (self.pos += 1) {
            const ch = self.pattern[self.pos];
            if (ch > 0x7F or len >= buf.len) return self.failSyntax("invalid unicode property name");
            buf[len] = @intCast(ch);
            len += 1;
        }
        if (len == 0 or self.pos >= self.pattern.len or self.pattern[self.pos] != '}') {
            return self.failSyntax("unterminated unicode property escape");
        }
        self.pos += 1; // consume '}'
        const spec = buf[0..len];
        if (unicode.lookupProperty(spec)) |ranges| {
            return .{ .code_points = ranges };
        }
        if (self.flags.unicode_sets and !negated) {
            if (unicode.lookupPropertyOfStrings(spec)) |strings| {
                return .{ .strings = strings };
            }
        }
        return self.failSyntax("unknown unicode property");
    }

    const ClassAtom = union(enum) {
        single: u21,
        builtin: BuiltinClass,
        unicode_prop: struct { ranges: []const unicode.Range, inverted: bool },
    };

    fn parseClassAtom(self: *Compiler) CompileError!ClassAtom {
        const c = self.pattern[self.pos];
        self.pos += 1;
        if (c != '\\') {
            if (self.flags.isUnicodeMode() and isLeadSurrogate(c) and self.pos < self.pattern.len and isTrailSurrogate(self.pattern[self.pos])) {
                const trail = self.pattern[self.pos];
                self.pos += 1;
                return .{ .single = combineSurrogates(c, trail) };
            }
            return .{ .single = c };
        }
        if (self.pos >= self.pattern.len) return self.failSyntax("unterminated escape in character class");
        const esc = self.pattern[self.pos];
        self.pos += 1;
        switch (esc) {
            'd' => return .{ .builtin = .digit },
            'D' => return .{ .builtin = .not_digit },
            'w' => return .{ .builtin = .word },
            'W' => return .{ .builtin = .not_word },
            's' => return .{ .builtin = .space },
            'S' => return .{ .builtin = .not_space },
            'b' => return .{ .single = 0x0008 },
            'B' => return self.failAnnexB("\\B inside character class"),
            'n' => return .{ .single = '\n' },
            'r' => return .{ .single = '\r' },
            't' => return .{ .single = '\t' },
            'f' => return .{ .single = 0x000C },
            'v' => return .{ .single = 0x000B },
            '0' => {
                if (self.pos < self.pattern.len and isAsciiDigit(self.pattern[self.pos])) {
                    return self.failAnnexB("legacy octal escape in character class");
                }
                return .{ .single = 0 };
            },
            '1'...'9' => return self.failAnnexB("decimal/octal escape in character class"),
            'x' => return .{ .single = try self.parseHexEscape(2) },
            'u' => return .{ .single = try self.parseUnicodeEscapeCp() },
            'c' => {
                if (self.pos < self.pattern.len) {
                    const next = self.pattern[self.pos];
                    if ((next >= 'A' and next <= 'Z') or (next >= 'a' and next <= 'z')) {
                        self.pos += 1;
                        return .{ .single = next & 0x1F };
                    }
                }
                return self.failAnnexB("invalid \\c control escape");
            },
            'p', 'P' => {
                const prop = try self.parseUnicodeProperty(esc == 'P');
                return .{ .unicode_prop = .{ .ranges = prop.code_points, .inverted = (esc == 'P') } };
            },
            'k' => {
                if (self.named_groups.items.len > 0 or self.flags.isUnicodeMode()) {
                    return self.failSyntax("\\k is not allowed in character class");
                }
                return self.failAnnexB("annex B \\k identity escape in character class");
            },
            else => {
                if (isSyntaxCharacter(esc) or esc == '/' or esc == '-') {
                    return .{ .single = esc };
                }
                if (self.flags.isUnicodeMode()) {
                    return self.failSyntax("invalid identity escape in unicode character class");
                }
                if ((esc >= 'a' and esc <= 'z') or (esc >= 'A' and esc <= 'Z')) {
                    return self.failAnnexB("annex B letter identity escape");
                }
                return .{ .single = esc };
            },
        }
    }

    fn appendClassNode(self: *Compiler, node: ClassNode) CompileError!u32 {
        if (self.class_nodes.items.len >= max_class_items) {
            return self.failComplex("too many character class items");
        }
        const idx: u32 = @intCast(self.class_nodes.items.len);
        try self.class_nodes.append(self.gpa, node);
        return idx;
    }

    fn appendClassAtomNode(self: *Compiler, atom: ClassAtom) CompileError!void {
        switch (atom) {
            .single => |ch| _ = try self.appendClassNode(.{ .range = .{ .lo = ch, .hi = ch } }),
            .builtin => |b| _ = try self.appendClassNode(.{ .builtin = b }),
            .unicode_prop => |p| {
                if (p.inverted) {
                    const child_idx = try self.appendClassNode(.{ .unicode_prop = p.ranges });
                    _ = try self.appendClassNode(.{
                        .compound = .{
                            .op = .union_op,
                            .inverted = true,
                            .ignore_case = self.flags.ignore_case,
                            .start = child_idx,
                            .len = 1,
                        },
                    });
                } else {
                    _ = try self.appendClassNode(.{ .unicode_prop = p.ranges });
                }
            },
        }
    }

    fn parseClass(self: *Compiler) CompileError!void {
        if (self.flags.unicode_sets) {
            return self.parseClassV();
        }
        var inverted = false;
        if (self.pos < self.pattern.len and self.pattern[self.pos] == '^') {
            inverted = true;
            self.pos += 1;
        }
        const nodes_start: u32 = @intCast(self.class_nodes.items.len);
        while (self.pos < self.pattern.len and self.pattern[self.pos] != ']') {
            const first = try self.parseClassAtom();
            if (self.pos < self.pattern.len and self.pattern[self.pos] == '-') {
                if (self.pos + 1 < self.pattern.len and self.pattern[self.pos + 1] == ']') {
                    // Trailing `-` before `]` is a literal `-`.
                    try self.appendClassAtomNode(first);
                    self.pos += 1;
                    _ = try self.appendClassNode(.{ .range = .{ .lo = '-', .hi = '-' } });
                    break;
                }
                self.pos += 1; // consume '-'
                const second = try self.parseClassAtom();
                if (first != .single or second != .single) {
                    if (self.flags.isUnicodeMode()) {
                        return self.failSyntax("character class range with character class escape");
                    }
                    try self.appendClassAtomNode(first);
                    _ = try self.appendClassNode(.{ .range = .{ .lo = '-', .hi = '-' } });
                    try self.appendClassAtomNode(second);
                    continue;
                }
                const lo = first.single;
                const hi = second.single;
                if (lo > hi) {
                    return self.failSyntax("character class range out of order");
                }
                _ = try self.appendClassNode(.{ .range = .{ .lo = lo, .hi = hi } });
            } else {
                try self.appendClassAtomNode(first);
            }
        }
        if (self.pos >= self.pattern.len or self.pattern[self.pos] != ']') {
            return self.failSyntax("unterminated character class");
        }
        self.pos += 1; // consume ']'

        const nodes_len: u32 = @intCast(self.class_nodes.items.len - nodes_start);
        const root_node = try self.appendClassNode(.{
            .compound = .{
                .op = .union_op,
                .inverted = inverted,
                .ignore_case = self.flags.ignore_case,
                .start = nodes_start,
                .len = nodes_len,
            },
        });
        const class_idx: u32 = @intCast(self.classes.items.len);
        try self.classes.append(self.gpa, .{
            .root_node = root_node,
            .has_strings = false,
            .max_str_len = 1,
        });
        const start_pc = try self.emitAtomInst(.{ .class = class_idx });
        self.last_atom = .{
            .start_pc = start_pc,
            .end_pc = start_pc + 1,
            .cap_start = self.next_capture + 1,
            .cap_end = self.next_capture,
            .quantifiable = true,
            .is_lookahead = false,
        };
    }

    fn parseVClassChar(self: *Compiler, in_q: bool) CompileError!u21 {
        if (self.pos >= self.pattern.len) return self.failSyntax("unterminated v-mode character class");
        const c = self.pattern[self.pos];
        self.pos += 1;
        if (c != '\\') {
            if (!in_q and isClassSetSyntaxChar(c)) {
                return self.failSyntax("unescaped syntax character in v-mode character class");
            }
            if (!in_q and isClassSetDoublePunctuatorChar(c) and
                self.pos < self.pattern.len and self.pattern[self.pos] == c)
            {
                return self.failSyntax("reserved double punctuator in v-mode character class");
            }
            if (isLeadSurrogate(c) and self.pos < self.pattern.len and isTrailSurrogate(self.pattern[self.pos])) {
                const trail = self.pattern[self.pos];
                self.pos += 1;
                return combineSurrogates(c, trail);
            }
            return c;
        }
        if (self.pos >= self.pattern.len) return self.failSyntax("unterminated escape in v-mode character class");
        const esc = self.pattern[self.pos];
        self.pos += 1;
        return switch (esc) {
            'b' => 0x0008,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'f' => 0x000C,
            'v' => 0x000B,
            '0' => blk: {
                if (self.pos < self.pattern.len and isAsciiDigit(self.pattern[self.pos])) {
                    return self.failSyntax("legacy octal escape in v-mode character class");
                }
                break :blk 0;
            },
            'x' => try self.parseHexEscape(2),
            'u' => try self.parseUnicodeEscapeCp(),
            'c' => blk: {
                if (self.pos < self.pattern.len) {
                    const next = self.pattern[self.pos];
                    if ((next >= 'A' and next <= 'Z') or (next >= 'a' and next <= 'z')) {
                        self.pos += 1;
                        break :blk next & 0x1F;
                    }
                }
                return self.failSyntax("invalid \\c control escape");
            },
            else => {
                if (isSyntaxCharacter(esc) or esc == '/' or isClassSetReservedPunctuator(esc)) {
                    return esc;
                }
                return self.failSyntax("invalid escape in v-mode character class");
            },
        };
    }

    fn parseClassV(self: *Compiler) CompileError!void {
        const ClassVFrame = struct {
            inverted: bool,
            op: ?ClassOp = null,
            may_contain_strings: bool = false,
            first_may_contain_strings: bool = false,
            max_str_len: u32 = 1,
            children: std.ArrayList(ClassNode) = .empty,
        };

        var stack: std.ArrayList(ClassVFrame) = .empty;
        defer {
            for (stack.items) |*f| f.children.deinit(self.gpa);
            stack.deinit(self.gpa);
        }

        const pushFrame = struct {
            fn call(comp: *Compiler, st: *std.ArrayList(ClassVFrame)) CompileError!void {
                if (comp.groups.items.len + st.items.len >= comp.max_depth) {
                    return comp.failDepth("regex character class nesting exceeds max_depth");
                }
                var inv = false;
                if (comp.pos < comp.pattern.len and comp.pattern[comp.pos] == '^') {
                    inv = true;
                    comp.pos += 1;
                }
                try st.append(comp.gpa, .{ .inverted = inv });
            }
        }.call;

        try pushFrame(self, &stack);

        while (stack.items.len > 0) {
            if (self.pos >= self.pattern.len) return self.failSyntax("unterminated character class");
            const cur = self.pattern[self.pos];

            if (cur == ']') {
                self.pos += 1;
                var frame = stack.pop().?;
                defer frame.children.deinit(self.gpa);

                if (frame.inverted and frame.may_contain_strings) {
                    return self.failSyntax("negated character class cannot contain strings");
                }
                const start: u32 = @intCast(self.class_nodes.items.len);
                if (self.class_nodes.items.len + frame.children.items.len >= max_class_items) {
                    return self.failComplex("too many character class items");
                }
                try self.class_nodes.appendSlice(self.gpa, frame.children.items);
                const compound_node: ClassNode = .{
                    .compound = .{
                        .op = frame.op orelse .union_op,
                        .inverted = frame.inverted,
                        .ignore_case = self.flags.ignore_case,
                        .start = start,
                        .len = @intCast(frame.children.items.len),
                    },
                };
                const effective_strings = if (frame.inverted) false else frame.may_contain_strings;

                if (stack.items.len == 0) {
                    const root_node = try self.appendClassNode(compound_node);
                    const class_idx: u32 = @intCast(self.classes.items.len);
                    try self.classes.append(self.gpa, .{
                        .root_node = root_node,
                        .has_strings = effective_strings,
                        .max_str_len = frame.max_str_len,
                    });
                    const start_pc = try self.emitAtomInst(.{ .class = class_idx });
                    self.last_atom = .{
                        .start_pc = start_pc,
                        .end_pc = start_pc + 1,
                        .cap_start = self.next_capture + 1,
                        .cap_end = self.next_capture,
                        .quantifiable = true,
                        .is_lookahead = false,
                    };
                    return;
                }

                const parent = &stack.items[stack.items.len - 1];
                try parent.children.append(self.gpa, compound_node);
                parent.max_str_len = @max(parent.max_str_len, frame.max_str_len);
                if (parent.children.items.len == 1) {
                    parent.first_may_contain_strings = effective_strings;
                    parent.may_contain_strings = effective_strings;
                } else {
                    switch (parent.op orelse .union_op) {
                        .union_op => parent.may_contain_strings = parent.may_contain_strings or effective_strings,
                        .intersection_op => parent.may_contain_strings = parent.may_contain_strings and effective_strings,
                        .subtraction_op => parent.may_contain_strings = parent.first_may_contain_strings,
                    }
                }
                // Check for operator after nested [...]
                if (self.pos + 1 < self.pattern.len and self.pattern[self.pos] == '&' and self.pattern[self.pos + 1] == '&') {
                    if (parent.op == .subtraction_op or parent.op == .union_op) return self.failSyntax("cannot mix class set operators");
                    if (self.pos + 2 < self.pattern.len and self.pattern[self.pos + 2] == '&') return self.failSyntax("invalid '&&&' in character class");
                    parent.op = .intersection_op;
                    self.pos += 2;
                    if (self.pos >= self.pattern.len or self.pattern[self.pos] == ']') return self.failSyntax("trailing '&&' in character class");
                } else if (self.pos + 1 < self.pattern.len and self.pattern[self.pos] == '-' and self.pattern[self.pos + 1] == '-') {
                    if (parent.op == .intersection_op or parent.op == .union_op) return self.failSyntax("cannot mix class set operators");
                    parent.op = .subtraction_op;
                    self.pos += 2;
                    if (self.pos >= self.pattern.len or self.pattern[self.pos] == ']') return self.failSyntax("trailing '--' in character class");
                } else if (self.pos < self.pattern.len and self.pattern[self.pos] != ']') {
                    if (parent.op == .intersection_op or parent.op == .subtraction_op) return self.failSyntax("cannot mix class set operators");
                    parent.op = .union_op;
                }
                continue;
            }

            if (cur == '[') {
                self.pos += 1;
                try pushFrame(self, &stack);
                continue;
            }

            const frame = &stack.items[stack.items.len - 1];
            if (self.pos + 1 < self.pattern.len and ((cur == '&' and self.pattern[self.pos + 1] == '&') or (cur == '-' and self.pattern[self.pos + 1] == '-'))) {
                return self.failSyntax("unexpected class set operator");
            }

            // Parse one ClassSetOperand
            var operand_node: ClassNode = undefined;
            var operand_has_strings = false;
            var operand_max_len: u32 = 1;

            if (cur == '\\' and self.pos + 1 < self.pattern.len) {
                const esc = self.pattern[self.pos + 1];
                switch (esc) {
                    'd' => {
                        self.pos += 2;
                        operand_node = .{ .builtin = .digit };
                    },
                    'D' => {
                        self.pos += 2;
                        operand_node = .{ .builtin = .not_digit };
                    },
                    'w' => {
                        self.pos += 2;
                        operand_node = .{ .builtin = .word };
                    },
                    'W' => {
                        self.pos += 2;
                        operand_node = .{ .builtin = .not_word };
                    },
                    's' => {
                        self.pos += 2;
                        operand_node = .{ .builtin = .space };
                    },
                    'S' => {
                        self.pos += 2;
                        operand_node = .{ .builtin = .not_space };
                    },
                    'p', 'P' => {
                        self.pos += 2;
                        const prop = try self.parseUnicodeProperty(esc == 'P');
                        switch (prop) {
                            .code_points => |ranges| {
                                if (esc == 'P') {
                                    const child_idx = try self.appendClassNode(.{ .unicode_prop = ranges });
                                    operand_node = .{
                                        .compound = .{
                                            .op = .union_op,
                                            .inverted = true,
                                            .ignore_case = self.flags.ignore_case,
                                            .start = child_idx,
                                            .len = 1,
                                        },
                                    };
                                } else {
                                    operand_node = .{ .unicode_prop = ranges };
                                }
                            },
                            .strings => |strings| {
                                operand_node = .{ .string_prop = strings };
                                operand_has_strings = true;
                                for (strings) |s| {
                                    operand_max_len = @max(operand_max_len, @as(u32, @intCast(s.len)));
                                }
                            },
                        }
                    },
                    'q' => {
                        self.pos += 2;
                        if (self.pos >= self.pattern.len or self.pattern[self.pos] != '{') {
                            return self.failSyntax("expected '{' after \\q");
                        }
                        self.pos += 1;
                        var alts: std.ArrayList(ClassNode) = .empty;
                        defer alts.deinit(self.gpa);
                        while (true) {
                            const str_start: u32 = @intCast(self.class_strings.items.len);
                            while (self.pos < self.pattern.len and self.pattern[self.pos] != '|' and self.pattern[self.pos] != '}') {
                                const ch = try self.parseVClassChar(true);
                                try self.class_strings.append(self.gpa, ch);
                            }
                            const str_len: u32 = @intCast(self.class_strings.items.len - str_start);
                            if (str_len == 1) {
                                const cp = self.class_strings.items[str_start];
                                self.class_strings.shrinkRetainingCapacity(str_start);
                                try alts.append(self.gpa, .{ .range = .{ .lo = cp, .hi = cp } });
                            } else {
                                operand_has_strings = true;
                                operand_max_len = @max(operand_max_len, str_len);
                                try alts.append(self.gpa, .{ .string_literal = .{ .start = str_start, .len = str_len } });
                            }
                            if (self.pos >= self.pattern.len) return self.failSyntax("unterminated \\q{...}");
                            if (self.pattern[self.pos] == '}') {
                                self.pos += 1;
                                break;
                            }
                            self.pos += 1; // consume '|'
                        }
                        if (alts.items.len == 1) {
                            operand_node = alts.items[0];
                        } else {
                            const start: u32 = @intCast(self.class_nodes.items.len);
                            if (self.class_nodes.items.len + alts.items.len >= max_class_items) {
                                return self.failComplex("too many character class items");
                            }
                            try self.class_nodes.appendSlice(self.gpa, alts.items);
                            operand_node = .{
                                .compound = .{
                                    .op = .union_op,
                                    .inverted = false,
                                    .ignore_case = self.flags.ignore_case,
                                    .start = start,
                                    .len = @intCast(alts.items.len),
                                },
                            };
                        }
                    },
                    else => {
                        const first_cp = try self.parseVClassChar(false);
                        if (self.pos < self.pattern.len and self.pattern[self.pos] == '-' and
                            !(self.pos + 1 < self.pattern.len and self.pattern[self.pos + 1] == '-'))
                        {
                            self.pos += 1; // consume '-'
                            const second_cp = try self.parseVClassChar(false);
                            if (first_cp > second_cp) return self.failSyntax("character class range out of order");
                            operand_node = .{ .range = .{ .lo = first_cp, .hi = second_cp } };
                        } else {
                            operand_node = .{ .range = .{ .lo = first_cp, .hi = first_cp } };
                        }
                    },
                }
            } else {
                const first_cp = try self.parseVClassChar(false);
                if (self.pos < self.pattern.len and self.pattern[self.pos] == '-' and
                    !(self.pos + 1 < self.pattern.len and self.pattern[self.pos + 1] == '-'))
                {
                    self.pos += 1; // consume '-'
                    const second_cp = try self.parseVClassChar(false);
                    if (first_cp > second_cp) return self.failSyntax("character class range out of order");
                    operand_node = .{ .range = .{ .lo = first_cp, .hi = second_cp } };
                } else {
                    operand_node = .{ .range = .{ .lo = first_cp, .hi = first_cp } };
                }
            }

            try frame.children.append(self.gpa, operand_node);
            frame.max_str_len = @max(frame.max_str_len, operand_max_len);
            if (frame.children.items.len == 1) {
                frame.first_may_contain_strings = operand_has_strings;
                frame.may_contain_strings = operand_has_strings;
            } else {
                switch (frame.op orelse .union_op) {
                    .union_op => frame.may_contain_strings = frame.may_contain_strings or operand_has_strings,
                    .intersection_op => frame.may_contain_strings = frame.may_contain_strings and operand_has_strings,
                    .subtraction_op => frame.may_contain_strings = frame.first_may_contain_strings,
                }
            }

            if (self.pos + 1 < self.pattern.len and self.pattern[self.pos] == '&' and self.pattern[self.pos + 1] == '&') {
                if (frame.op == .subtraction_op or frame.op == .union_op) return self.failSyntax("cannot mix class set operators");
                if (self.pos + 2 < self.pattern.len and self.pattern[self.pos + 2] == '&') return self.failSyntax("invalid '&&&' in character class");
                frame.op = .intersection_op;
                self.pos += 2;
                if (self.pos >= self.pattern.len or self.pattern[self.pos] == ']') return self.failSyntax("trailing '&&' in character class");
            } else if (self.pos + 1 < self.pattern.len and self.pattern[self.pos] == '-' and self.pattern[self.pos + 1] == '-') {
                if (frame.op == .intersection_op or frame.op == .union_op) return self.failSyntax("cannot mix class set operators");
                frame.op = .subtraction_op;
                self.pos += 2;
                if (self.pos >= self.pattern.len or self.pattern[self.pos] == ']') return self.failSyntax("trailing '--' in character class");
            } else if (self.pos < self.pattern.len and self.pattern[self.pos] != ']') {
                if (frame.op == .intersection_op or frame.op == .subtraction_op) return self.failSyntax("cannot mix class set operators");
                frame.op = .union_op;
            }
        }
    }

    fn parseAtomEscape(self: *Compiler) CompileError!void {
        if (self.pos >= self.pattern.len) return self.failSyntax("escape at end of pattern");
        const esc = self.pattern[self.pos];
        self.pos += 1;
        switch (esc) {
            'b' => {
                const inst: Inst = if (self.flags.ignore_case and self.flags.isUnicodeMode())
                    .word_boundary_icase
                else
                    .word_boundary;
                const pc = try self.emitAtomInst(inst);
                self.last_atom = .{ .start_pc = pc, .end_pc = pc + 1, .cap_start = 1, .cap_end = 0, .quantifiable = false, .is_lookahead = false };
            },
            'B' => {
                const inst: Inst = if (self.flags.ignore_case and self.flags.isUnicodeMode())
                    .not_word_boundary_icase
                else
                    .not_word_boundary;
                const pc = try self.emitAtomInst(inst);
                self.last_atom = .{ .start_pc = pc, .end_pc = pc + 1, .cap_start = 1, .cap_end = 0, .quantifiable = false, .is_lookahead = false };
            },
            'd' => try self.emitBuiltinAtom(.digit),
            'D' => try self.emitBuiltinAtom(.not_digit),
            'w' => try self.emitBuiltinAtom(.word),
            'W' => try self.emitBuiltinAtom(.not_word),
            's' => try self.emitBuiltinAtom(.space),
            'S' => try self.emitBuiltinAtom(.not_space),
            'n' => try self.emitLiteral('\n'),
            'r' => try self.emitLiteral('\r'),
            't' => try self.emitLiteral('\t'),
            'f' => try self.emitLiteral(0x000C),
            'v' => try self.emitLiteral(0x000B),
            '0' => {
                if (self.pos < self.pattern.len and isAsciiDigit(self.pattern[self.pos])) {
                    return self.failAnnexB("legacy octal escape");
                }
                try self.emitLiteral(0);
            },
            '1'...'9' => {
                var num: u32 = esc - '0';
                while (self.pos < self.pattern.len and isAsciiDigit(self.pattern[self.pos])) {
                    num = num *| 10 +| (self.pattern[self.pos] - '0');
                    self.pos += 1;
                }
                if (num > self.total_captures) {
                    return self.failAnnexB("backreference exceeds number of capturing groups");
                }
                const cap_idx: u16 = @intCast(num);
                const inst: Inst = if (self.flags.ignore_case)
                    .{ .backref_icase = cap_idx }
                else
                    .{ .backref = cap_idx };
                const start_pc = try self.emitAtomInst(inst);
                self.last_atom = .{
                    .start_pc = start_pc,
                    .end_pc = start_pc + 1,
                    .cap_start = self.next_capture + 1,
                    .cap_end = self.next_capture,
                    .quantifiable = true,
                    .is_lookahead = false,
                };
            },
            'x' => {
                const c = try self.parseHexEscape(2);
                try self.emitLiteral(c);
            },
            'u' => {
                const cp = try self.parseUnicodeEscapeCp();
                try self.emitLiteral(cp);
            },
            'c' => {
                if (self.pos < self.pattern.len) {
                    const next = self.pattern[self.pos];
                    if ((next >= 'A' and next <= 'Z') or (next >= 'a' and next <= 'z')) {
                        self.pos += 1;
                        try self.emitLiteral(next & 0x1F);
                        return;
                    }
                }
                return self.failAnnexB("invalid \\c control escape");
            },
            'p', 'P' => {
                const prop = try self.parseUnicodeProperty(esc == 'P');
                var has_strings = false;
                var max_str_len: u32 = 1;
                const node: ClassNode = switch (prop) {
                    .code_points => |ranges| .{ .unicode_prop = ranges },
                    .strings => |strings| blk: {
                        has_strings = true;
                        for (strings) |s| max_str_len = @max(max_str_len, @as(u32, @intCast(s.len)));
                        break :blk .{ .string_prop = strings };
                    },
                };
                const child_idx = try self.appendClassNode(node);
                const root_node = try self.appendClassNode(.{
                    .compound = .{
                        .op = .union_op,
                        .inverted = (esc == 'P'),
                        .ignore_case = self.flags.ignore_case,
                        .start = child_idx,
                        .len = 1,
                    },
                });
                const class_idx: u32 = @intCast(self.classes.items.len);
                try self.classes.append(self.gpa, .{
                    .root_node = root_node,
                    .has_strings = has_strings,
                    .max_str_len = max_str_len,
                });
                const start_pc = try self.emitAtomInst(.{ .class = class_idx });
                self.last_atom = .{
                    .start_pc = start_pc,
                    .end_pc = start_pc + 1,
                    .cap_start = self.next_capture + 1,
                    .cap_end = self.next_capture,
                    .quantifiable = true,
                    .is_lookahead = false,
                };
            },
            'k' => {
                if (self.named_groups.items.len == 0) {
                    return self.failAnnexB("annex B \\k identity escape");
                }
                if (self.pos >= self.pattern.len or self.pattern[self.pos] != '<') {
                    return self.failSyntax("invalid named backreference");
                }
                self.pos += 1;
                const parsed = try self.parseGroupNameAt(self.pos);
                defer self.gpa.free(parsed.name);
                self.pos = parsed.next_pos;
                const cap_idx = self.findNamedGroup(parsed.name) orelse {
                    return self.failSyntax("unknown named capture group");
                };
                const inst: Inst = if (self.flags.ignore_case)
                    .{ .backref_icase = cap_idx }
                else
                    .{ .backref = cap_idx };
                const start_pc = try self.emitAtomInst(inst);
                self.last_atom = .{
                    .start_pc = start_pc,
                    .end_pc = start_pc + 1,
                    .cap_start = self.next_capture + 1,
                    .cap_end = self.next_capture,
                    .quantifiable = true,
                    .is_lookahead = false,
                };
            },
            else => {
                if (isSyntaxCharacter(esc) or esc == '/') {
                    try self.emitLiteral(esc);
                } else if (self.flags.isUnicodeMode()) {
                    return self.failSyntax("invalid identity escape in unicode mode");
                } else if ((esc >= 'a' and esc <= 'z') or (esc >= 'A' and esc <= 'Z')) {
                    return self.failAnnexB("annex B letter identity escape");
                } else {
                    try self.emitLiteral(esc);
                }
            },
        }
    }

    fn emitBuiltinAtom(self: *Compiler, b: BuiltinClass) CompileError!void {
        const start_pc = try self.emitAtomInst(.{
            .builtin = .{
                .class = b,
                .unicode_icase = self.flags.ignore_case and self.flags.isUnicodeMode(),
            },
        });
        self.last_atom = .{
            .start_pc = start_pc,
            .end_pc = start_pc + 1,
            .cap_start = self.next_capture + 1,
            .cap_end = self.next_capture,
            .quantifiable = true,
            .is_lookahead = false,
        };
    }

    fn parseInlineModifiers(self: *Compiler) CompileError!Flags {
        var new_flags = self.flags;
        var seen_add_i = false;
        var seen_add_m = false;
        var seen_add_s = false;
        var seen_rem_i = false;
        var seen_rem_m = false;
        var seen_rem_s = false;
        var in_remove = false;
        var has_any_flag = false;

        while (self.pos < self.pattern.len) {
            const ch = self.pattern[self.pos];
            self.pos += 1;
            if (ch == ':') {
                if (!has_any_flag) return self.failSyntax("invalid group modifier");
                return new_flags;
            }
            if (ch == '-') {
                if (in_remove) return self.failSyntax("invalid group modifier");
                in_remove = true;
                continue;
            }
            has_any_flag = true;
            switch (ch) {
                'i' => {
                    if (in_remove) {
                        if (seen_add_i or seen_rem_i) return self.failSyntax("duplicate group modifier");
                        seen_rem_i = true;
                        new_flags.ignore_case = false;
                    } else {
                        if (seen_add_i) return self.failSyntax("duplicate group modifier");
                        seen_add_i = true;
                        new_flags.ignore_case = true;
                    }
                },
                'm' => {
                    if (in_remove) {
                        if (seen_add_m or seen_rem_m) return self.failSyntax("duplicate group modifier");
                        seen_rem_m = true;
                        new_flags.multiline = false;
                    } else {
                        if (seen_add_m) return self.failSyntax("duplicate group modifier");
                        seen_add_m = true;
                        new_flags.multiline = true;
                    }
                },
                's' => {
                    if (in_remove) {
                        if (seen_add_s or seen_rem_s) return self.failSyntax("duplicate group modifier");
                        seen_rem_s = true;
                        new_flags.dot_all = false;
                    } else {
                        if (seen_add_s) return self.failSyntax("duplicate group modifier");
                        seen_add_s = true;
                        new_flags.dot_all = true;
                    }
                },
                else => return self.failSyntax("invalid group modifier"),
            }
        }
        return self.failSyntax("unterminated group modifier");
    }

    fn openGroup(self: *Compiler) CompileError!void {
        if (self.groups.items.len >= self.max_depth) {
            return self.failDepth("regex nesting exceeds max_depth");
        }
        var kind: GroupKind = .capturing;
        var cap_idx: u16 = 0;
        const cap_before = self.next_capture;
        const saved_flags = self.flags;
        const saved_in_lookbehind = self.in_lookbehind;

        if (self.pos < self.pattern.len and self.pattern[self.pos] == '?') {
            self.pos += 1;
            if (self.pos >= self.pattern.len) return self.failSyntax("unterminated group");
            const sub = self.pattern[self.pos];
            self.pos += 1;
            switch (sub) {
                ':' => kind = .non_capturing,
                '=' => kind = .pos_lookahead,
                '!' => kind = .neg_lookahead,
                '<' => {
                    if (self.pos >= self.pattern.len) return self.failSyntax("unterminated group");
                    if (self.pattern[self.pos] == '=') {
                        self.pos += 1;
                        kind = .pos_lookbehind;
                    } else if (self.pattern[self.pos] == '!') {
                        self.pos += 1;
                        kind = .neg_lookbehind;
                    } else {
                        // Named capturing group (?<name>...) already validated in prepass.
                        while (self.pos < self.pattern.len and self.pattern[self.pos] != '>') : (self.pos += 1) {}
                        if (self.pos >= self.pattern.len) return self.failSyntax("unterminated capture group name");
                        self.pos += 1; // consume '>'
                        self.next_capture += 1;
                        cap_idx = self.next_capture;
                    }
                },
                'i', 'm', 's', '-' => {
                    self.pos -= 1;
                    self.flags = try self.parseInlineModifiers();
                    kind = .non_capturing;
                },
                else => return self.failSyntax("invalid group modifier"),
            }
        } else {
            self.next_capture += 1;
            cap_idx = self.next_capture;
        }

        const term_start_pc: u32 = @intCast(self.insts.items.len);
        var lookahead_pc: u32 = 0;
        switch (kind) {
            .capturing => _ = try self.emit(if (self.in_lookbehind) .{ .save_end = cap_idx } else .{ .save_start = cap_idx }),
            .non_capturing => {},
            .pos_lookahead, .neg_lookahead => {
                lookahead_pc = try self.emit(.{
                    .lookahead = .{
                        .negative = (kind == .neg_lookahead),
                        .reverse = false,
                        .body_pc = term_start_pc + 1,
                        .next_pc = 0, // patched on closeGroup
                        .cap_start = cap_before + 1,
                        .cap_end = cap_before,
                    },
                });
                self.in_lookbehind = false;
            },
            .pos_lookbehind, .neg_lookbehind => {
                lookahead_pc = try self.emit(.{
                    .lookahead = .{
                        .negative = (kind == .neg_lookbehind),
                        .reverse = true,
                        .body_pc = term_start_pc + 1,
                        .next_pc = 0, // patched on closeGroup
                        .cap_start = cap_before + 1,
                        .cap_end = cap_before,
                    },
                });
                self.in_lookbehind = true;
            },
        }
        const branch_start_pc: u32 = @intCast(self.insts.items.len);

        try self.groups.append(self.gpa, .{
            .kind = kind,
            .capture_index = cap_idx,
            .cap_before = cap_before,
            .term_start_pc = term_start_pc,
            .branch_start_pc = branch_start_pc,
            .saved_flags = saved_flags,
            .saved_in_lookbehind = saved_in_lookbehind,
            .lookahead_pc = lookahead_pc,
        });
        self.last_atom = null;
    }

    fn handleAlternation(self: *Compiler) CompileError!void {
        if (self.groups.items.len > 0) {
            const b_start = self.groups.items[self.groups.items.len - 1].branch_start_pc;
            try self.insertInstAt(b_start, .{
                .split = .{
                    .first = b_start + 1,
                    .second = @intCast(self.insts.items.len + 2),
                },
            });
            const jump_pc = try self.emit(.{ .jump = 0 });
            const g = &self.groups.items[self.groups.items.len - 1];
            try g.end_jumps.append(self.gpa, jump_pc);
            g.branch_start_pc = @intCast(self.insts.items.len);
        } else {
            const b_start = self.top_branch_start_pc;
            try self.insertInstAt(b_start, .{
                .split = .{
                    .first = b_start + 1,
                    .second = @intCast(self.insts.items.len + 2),
                },
            });
            const jump_pc = try self.emit(.{ .jump = 0 });
            try self.top_end_jumps.append(self.gpa, jump_pc);
            self.top_branch_start_pc = @intCast(self.insts.items.len);
        }
        self.last_atom = null;
    }

    fn closeGroup(self: *Compiler) CompileError!void {
        if (self.groups.items.len == 0) {
            return self.failSyntax("unmatched ')'");
        }
        var g = self.groups.pop().?;
        defer g.end_jumps.deinit(self.gpa);

        const end_pc: u32 = @intCast(self.insts.items.len);
        for (g.end_jumps.items) |j| {
            self.insts.items[j].jump = end_pc;
        }

        self.flags = g.saved_flags;
        self.in_lookbehind = g.saved_in_lookbehind;

        var quantifiable = true;
        var is_assertion = false;
        switch (g.kind) {
            .capturing => {
                _ = try self.emit(if (self.in_lookbehind) .{ .save_start = g.capture_index } else .{ .save_end = g.capture_index });
            },
            .non_capturing => {},
            .pos_lookahead, .neg_lookahead, .pos_lookbehind, .neg_lookbehind => {
                const done_pc = try self.emit(.lookahead_done);
                self.insts.items[g.lookahead_pc].lookahead.next_pc = done_pc + 1;
                self.insts.items[g.lookahead_pc].lookahead.cap_start = g.cap_before + 1;
                self.insts.items[g.lookahead_pc].lookahead.cap_end = self.next_capture;
                quantifiable = false;
                is_assertion = true;
            },
        }

        const group_end_pc: u32 = @intCast(self.insts.items.len);
        var start_pc = g.term_start_pc;
        if (self.in_lookbehind) {
            const dst = self.currentBranchStartPc();
            self.moveInstRange(dst, g.term_start_pc, group_end_pc);
            start_pc = dst;
        }
        self.last_atom = .{
            .start_pc = start_pc,
            .end_pc = start_pc + (group_end_pc - g.term_start_pc),
            .cap_start = g.cap_before + 1,
            .cap_end = self.next_capture,
            .quantifiable = quantifiable,
            .is_lookahead = is_assertion,
        };
    }

    fn parseBracedQuantifier(self: *Compiler) CompileError!?struct { min: u32, max: u32 } {
        var i = self.pos;
        if (i >= self.pattern.len or !isAsciiDigit(self.pattern[i])) {
            return null;
        }
        var min: u64 = 0;
        while (i < self.pattern.len and isAsciiDigit(self.pattern[i])) : (i += 1) {
            min = min *| 10 +| (self.pattern[i] - '0');
        }
        var max: u64 = min;
        if (i < self.pattern.len and self.pattern[i] == ',') {
            i += 1;
            if (i < self.pattern.len and isAsciiDigit(self.pattern[i])) {
                max = 0;
                while (i < self.pattern.len and isAsciiDigit(self.pattern[i])) : (i += 1) {
                    max = max *| 10 +| (self.pattern[i] - '0');
                }
            } else {
                max = std.math.maxInt(u32);
            }
        }
        if (i >= self.pattern.len or self.pattern[i] != '}') {
            return null;
        }
        self.pos = i + 1;
        if (max != std.math.maxInt(u32) and min > max) {
            return self.failSyntax("numbers out of order in {} quantifier");
        }
        if (min > max_quantifier_bound or (max != std.math.maxInt(u32) and max > max_quantifier_bound)) {
            return self.failComplex("quantifier bound exceeds limit");
        }
        return .{ .min = @intCast(min), .max = @intCast(max) };
    }

    fn applyQuantifier(self: *Compiler, min: u32, max: u32) CompileError!void {
        const atom = self.last_atom orelse return self.failSyntax("nothing to repeat");
        if (atom.is_lookahead) {
            return self.failAnnexB("quantifier on lookahead assertion");
        }
        if (!atom.quantifiable) {
            return self.failSyntax("nothing to repeat");
        }
        var greedy = true;
        if (self.pos < self.pattern.len and self.pattern[self.pos] == '?') {
            greedy = false;
            self.pos += 1;
        }

        if (self.loops.items.len >= max_loops) {
            return self.failComplex("too many quantified expressions");
        }
        const loop_id: u16 = @intCast(self.loops.items.len);
        try self.loops.append(self.gpa, .{
            .min = min,
            .max = max,
            .greedy = greedy,
            .cap_start = atom.cap_start,
            .cap_end = atom.cap_end,
        });

        try self.insertInstAt(atom.start_pc, .{
            .loop_init = .{
                .loop_id = loop_id,
                .step_pc = 0, // patched below
            },
        });
        const step_pc = atom.end_pc + 1;
        try self.insertInstAt(step_pc, .{
            .loop_step = .{
                .loop_id = loop_id,
                .body_pc = atom.start_pc + 1,
                .exit_pc = step_pc + 1,
            },
        });
        self.insts.items[atom.start_pc].loop_init.step_pc = step_pc;
        self.last_atom = null;
    }

    fn compileAll(self: *Compiler) CompileError!Program {
        self.total_captures = try self.countCapturesPrepass();

        while (self.pos < self.pattern.len) {
            const c = self.pattern[self.pos];
            self.pos += 1;
            switch (c) {
                '^' => {
                    const pc = try self.emitAtomInst(if (self.flags.multiline) .bol_multiline else .bol);
                    self.last_atom = .{ .start_pc = pc, .end_pc = pc + 1, .cap_start = 1, .cap_end = 0, .quantifiable = false, .is_lookahead = false };
                },
                '$' => {
                    const pc = try self.emitAtomInst(if (self.flags.multiline) .eol_multiline else .eol);
                    self.last_atom = .{ .start_pc = pc, .end_pc = pc + 1, .cap_start = 1, .cap_end = 0, .quantifiable = false, .is_lookahead = false };
                },
                '.' => {
                    const pc = try self.emitAtomInst(if (self.flags.dot_all) .any_dot_all else .any);
                    self.last_atom = .{
                        .start_pc = pc,
                        .end_pc = pc + 1,
                        .cap_start = self.next_capture + 1,
                        .cap_end = self.next_capture,
                        .quantifiable = true,
                        .is_lookahead = false,
                    };
                },
                '\\' => try self.parseAtomEscape(),
                '[' => try self.parseClass(),
                ']' => {
                    if (self.flags.isUnicodeMode()) return self.failSyntax("unescaped ']' outside character class");
                    try self.emitLiteral(']');
                },
                '(' => try self.openGroup(),
                ')' => try self.closeGroup(),
                '|' => try self.handleAlternation(),
                '*' => try self.applyQuantifier(0, std.math.maxInt(u32)),
                '+' => try self.applyQuantifier(1, std.math.maxInt(u32)),
                '?' => try self.applyQuantifier(0, 1),
                '{' => {
                    if (try self.parseBracedQuantifier()) |q| {
                        try self.applyQuantifier(q.min, q.max);
                    } else {
                        if (self.flags.isUnicodeMode()) return self.failSyntax("unescaped '{' that does not form a quantifier");
                        try self.emitLiteral('{');
                    }
                },
                '}' => {
                    if (self.flags.isUnicodeMode()) return self.failSyntax("unescaped '}' outside quantifier");
                    try self.emitLiteral('}');
                },
                else => {
                    var cp: u21 = c;
                    if (self.flags.isUnicodeMode() and isLeadSurrogate(c) and self.pos < self.pattern.len and isTrailSurrogate(self.pattern[self.pos])) {
                        cp = combineSurrogates(c, self.pattern[self.pos]);
                        self.pos += 1;
                    }
                    try self.emitLiteral(cp);
                },
            }
        }

        if (self.groups.items.len != 0) {
            return self.failSyntax("unterminated group");
        }

        const end_pc: u32 = @intCast(self.insts.items.len);
        for (self.top_end_jumps.items) |j| {
            self.insts.items[j].jump = end_pc;
        }
        _ = try self.emit(.match);

        const insts = try self.insts.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(insts);
        const classes = try self.classes.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(classes);
        const class_nodes = try self.class_nodes.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(class_nodes);
        const class_strings = try self.class_strings.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(class_strings);
        const loops = try self.loops.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(loops);
        const named_groups = try self.named_groups.toOwnedSlice(self.gpa);

        return .{
            .insts = insts,
            .classes = classes,
            .class_nodes = class_nodes,
            .class_strings = class_strings,
            .loops = loops,
            .named_groups = named_groups,
            .capture_count = self.total_captures,
            .loop_count = @intCast(loops.len),
            .flags = self.flags,
        };
    }
};

pub fn compile(gpa: Allocator, pattern: []const u16, flags: Flags, diag: *Diagnostic) CompileError!Program {
    return compileWithDepth(gpa, pattern, flags, max_depth, diag);
}

pub fn compileWithDepth(gpa: Allocator, pattern: []const u16, flags: Flags, depth_limit: u16, diag: *Diagnostic) CompileError!Program {
    diag.* = .{};
    var compiler: Compiler = .{
        .gpa = gpa,
        .pattern = pattern,
        .flags = flags,
        .max_depth = @min(depth_limit, max_depth),
        .diag = diag,
    };
    defer compiler.deinit();
    return compiler.compileAll();
}

const unset_pos: u32 = std.math.maxInt(u32);

const LoopState = struct {
    count: u32 = 0,
    last_idx: u32 = unset_pos,
};

const Action = union(enum) {
    branch: struct {
        pc: u32,
        idx: u32,
        reverse: bool,
        cap_base: u32,
        loop_base: u32,
    },
    lookahead_neg_success: struct {
        next_pc: u32,
        idx: u32,
        saved_reverse: bool,
        cap_base: u32,
        loop_base: u32,
    },
};

const LookaheadMarker = struct {
    negative: bool,
    saved_reverse: bool,
    next_pc: u32,
    saved_idx: u32,
    action_watermark: u32,
    cap_watermark: u32,
    loop_watermark: u32,
};

const EvalFrame = struct {
    node_idx: u32,
    child_pos: u32,
    acc: bool,
    ignore_case: bool,
};

/// Stack-backed growable list that avoids heap allocation for small counts and spills
/// transparently to `gpa` when capacity exceeds `inline_cap`. Stores no self-referential
/// pointers so containing structs can move freely.
fn SmallList(comptime T: type, comptime inline_cap: usize) type {
    return struct {
        const Self = @This();

        len: usize = 0,
        heap: std.ArrayList(T) = .empty,
        inline_buf: [inline_cap]T = undefined,

        inline fn items(self: *Self) []T {
            return if (self.heap.capacity > 0) self.heap.items else self.inline_buf[0..self.len];
        }

        fn deinit(self: *Self, gpa: Allocator) void {
            self.heap.deinit(gpa);
        }

        inline fn clearRetainingCapacity(self: *Self) void {
            if (self.heap.capacity > 0) {
                self.heap.clearRetainingCapacity();
            } else {
                self.len = 0;
            }
        }

        inline fn shrinkRetainingCapacity(self: *Self, new_len: usize) void {
            if (self.heap.capacity > 0) {
                self.heap.shrinkRetainingCapacity(new_len);
            } else {
                self.len = new_len;
            }
        }

        inline fn pop(self: *Self) ?T {
            if (self.heap.capacity > 0) return self.heap.pop();
            if (self.len == 0) return null;
            self.len -= 1;
            return self.inline_buf[self.len];
        }

        fn spill(self: *Self, gpa: Allocator, needed_total: usize) Allocator.Error!void {
            try self.heap.ensureTotalCapacity(gpa, @max(needed_total, inline_cap * 2));
            self.heap.appendSliceAssumeCapacity(self.inline_buf[0..self.len]);
        }

        fn ensureUnusedCapacity(self: *Self, gpa: Allocator, additional: usize) Allocator.Error!void {
            if (self.heap.capacity > 0) {
                try self.heap.ensureUnusedCapacity(gpa, additional);
            } else if (self.len + additional > inline_cap) {
                try self.spill(gpa, self.len + additional);
            }
        }

        inline fn appendAssumeCapacity(self: *Self, item: T) void {
            if (self.heap.capacity > 0) {
                self.heap.appendAssumeCapacity(item);
            } else {
                self.inline_buf[self.len] = item;
                self.len += 1;
            }
        }

        fn append(self: *Self, gpa: Allocator, item: T) Allocator.Error!void {
            try self.ensureUnusedCapacity(gpa, 1);
            self.appendAssumeCapacity(item);
        }

        fn appendSlice(self: *Self, gpa: Allocator, s: []const T) Allocator.Error!void {
            if (s.len == 0) return;
            try self.ensureUnusedCapacity(gpa, s.len);
            if (self.heap.capacity > 0) {
                self.heap.appendSliceAssumeCapacity(s);
            } else {
                @memcpy(self.inline_buf[self.len .. self.len + s.len], s);
                self.len += s.len;
            }
        }
    };
}

const Matcher = struct {
    gpa: Allocator,
    p: *const Program,
    input: []const u16,
    steps: *u64,
    reverse: bool = false,

    /// Current capture slots: 2 slots (start, end) per capture index `1..capture_count`.
    /// Index `2 * (cap - 1)` is start, `2 * (cap - 1) + 1` is end.
    caps: []u32,
    caps_heap: bool = false,
    /// Current loop counter states: 1 per `0..loop_count`.
    loops: []LoopState,
    loops_heap: bool = false,

    /// Flat pools storing snapshots of `caps` and `loops` pushed onto `actions`.
    /// Stack-backed for small backtracking depths so common patterns do zero heap allocations.
    cap_pool: SmallList(u32, 128) = .{},
    loop_pool: SmallList(LoopState, 128) = .{},
    actions: SmallList(Action, 64) = .{},
    markers: SmallList(LookaheadMarker, 8) = .{},
    eval_stack: SmallList(EvalFrame, 8) = .{},

    fn deinit(self: *Matcher) void {
        self.cap_pool.deinit(self.gpa);
        self.loop_pool.deinit(self.gpa);
        self.actions.deinit(self.gpa);
        self.markers.deinit(self.gpa);
        self.eval_stack.deinit(self.gpa);
        if (self.caps_heap) self.gpa.free(self.caps);
        if (self.loops_heap) self.gpa.free(self.loops);
    }

    fn chargeStep(self: *Matcher) ExecError!void {
        if (self.steps.* == 0) return error.StepLimit;
        self.steps.* -= 1;
    }

    fn pushSnapshot(self: *Matcher) ExecError!struct { cap_base: u32, loop_base: u32 } {
        // Saved states are bounded by the step budget (each comes from a charged
        // instruction) and memory by the allocator; this only keeps u32 indices valid.
        const cap_items = self.cap_pool.items();
        const loop_items = self.loop_pool.items();
        if (self.actions.items().len >= max_backtrack_states or
            cap_items.len + self.caps.len > max_backtrack_cells or
            loop_items.len + self.loops.len > max_backtrack_cells)
        {
            return error.OutOfMemory;
        }
        const cap_base: u32 = @intCast(cap_items.len);
        try self.cap_pool.appendSlice(self.gpa, self.caps);
        errdefer self.cap_pool.shrinkRetainingCapacity(cap_base);
        const loop_base: u32 = @intCast(loop_items.len);
        try self.loop_pool.appendSlice(self.gpa, self.loops);
        return .{ .cap_base = cap_base, .loop_base = loop_base };
    }

    fn pushBranch(self: *Matcher, pc: u32, idx: u32) ExecError!void {
        try self.actions.ensureUnusedCapacity(self.gpa, 1);
        const snap = try self.pushSnapshot();
        self.actions.appendAssumeCapacity(.{
            .branch = .{
                .pc = pc,
                .idx = idx,
                .reverse = self.reverse,
                .cap_base = snap.cap_base,
                .loop_base = snap.loop_base,
            },
        });
    }

    fn restoreSnapshot(self: *Matcher, cap_base: u32, loop_base: u32) void {
        @memcpy(self.caps, self.cap_pool.items()[cap_base..][0..self.caps.len]);
        @memcpy(self.loops, self.loop_pool.items()[loop_base..][0..self.loops.len]);
        self.cap_pool.shrinkRetainingCapacity(cap_base);
        self.loop_pool.shrinkRetainingCapacity(loop_base);
    }

    fn clearCaptures(self: *Matcher, cap_start: u16, cap_end: u16) void {
        if (cap_start > cap_end) return;
        const start_slot = (@as(usize, cap_start) - 1) * 2;
        const end_slot = @as(usize, cap_end) * 2;
        @memset(self.caps[start_slot..end_slot], unset_pos);
    }

    fn canonicalize(self: *const Matcher, cp: u21) u21 {
        return if (self.p.flags.isUnicodeMode())
            unicode.canonicalizeUnicode(cp)
        else
            unicode.canonicalizeLegacy(@intCast(cp));
    }

    fn matchesIcase(self: *const Matcher, a: u21, b: u21) bool {
        return self.canonicalize(a) == self.canonicalize(b);
    }

    fn matchesRangeIcase(self: *const Matcher, lo: u21, hi: u21, cp: u21) bool {
        if (cp >= lo and cp <= hi) return true;
        const canon_cp = self.canonicalize(cp);
        if (lo == hi) return canon_cp == self.canonicalize(lo);
        if (canon_cp >= lo and canon_cp <= hi) return true;
        if (canon_cp < 128 and ((canon_cp >= 'a' and canon_cp <= 'z') or (canon_cp >= 'A' and canon_cp <= 'Z'))) {
            const flipped = canon_cp ^ 32;
            if (flipped >= lo and flipped <= hi) return true;
        }
        if (hi > 0x7F and hi - lo <= 1024) {
            var x = lo;
            while (x <= hi) : (x += 1) {
                if (self.canonicalize(x) == canon_cp) return true;
            }
        }
        return false;
    }

    fn matchesCpSlice(self: *const Matcher, a: []const u21, b: []const u21, icase: bool) bool {
        if (a.len != b.len) return false;
        if (!icase) return std.mem.eql(u21, a, b);
        for (a, b) |ca, cb| {
            if (!self.matchesIcase(ca, cb)) return false;
        }
        return true;
    }

    fn evalLeafNode(self: *const Matcher, node: ClassNode, cps: []const u21, icase: bool) bool {
        switch (node) {
            .range => |r| {
                if (cps.len != 1) return false;
                if (icase) return self.matchesRangeIcase(r.lo, r.hi, cps[0]);
                return cps[0] >= r.lo and cps[0] <= r.hi;
            },
            .builtin => |b| return cps.len == 1 and matchesBuiltin(b, cps[0], icase and self.p.flags.isUnicodeMode()),
            .unicode_prop => |ranges| {
                if (cps.len != 1) return false;
                const cp = cps[0];
                if (unicode.inRanges(cp, ranges)) return true;
                if (!icase) return false;
                const canon = self.canonicalize(cp);
                if (unicode.inRanges(canon, ranges)) return true;
                if (canon >= 'a' and canon <= 'z') {
                    if (unicode.inRanges(canon - 32, ranges)) return true;
                    if (canon == 's' and unicode.inRanges(0x017F, ranges)) return true;
                    if (canon == 'k' and unicode.inRanges(0x212A, ranges)) return true;
                }
                return false;
            },
            .string_prop => |strings| {
                for (strings) |s| {
                    if (self.matchesCpSlice(s, cps, icase)) return true;
                }
                return false;
            },
            .string_literal => |sl| {
                const target = self.p.class_strings[sl.start..][0..sl.len];
                return self.matchesCpSlice(target, cps, icase);
            },
            .compound => unreachable,
        }
    }

    fn matchesClassSlice(self: *Matcher, root_node: u32, cps: []const u21) ExecError!bool {
        self.eval_stack.clearRetainingCapacity();

        const combine = struct {
            fn apply(frame: *EvalFrame, op: ClassOp, child_res: bool, total_len: u32) void {
                switch (op) {
                    .union_op => {
                        frame.acc = frame.acc or child_res;
                        if (frame.acc) frame.child_pos = total_len;
                    },
                    .intersection_op => {
                        frame.acc = frame.acc and child_res;
                        if (!frame.acc) frame.child_pos = total_len;
                    },
                    .subtraction_op => {
                        if (frame.child_pos == 1) {
                            frame.acc = child_res;
                        } else {
                            frame.acc = frame.acc and !child_res;
                        }
                        if (!frame.acc) frame.child_pos = total_len;
                    },
                }
            }
        }.apply;

        const root = self.p.class_nodes[root_node];
        switch (root) {
            .compound => |c| {
                try self.eval_stack.append(self.gpa, .{
                    .node_idx = root_node,
                    .child_pos = 0,
                    .acc = (c.op == .intersection_op),
                    .ignore_case = c.ignore_case,
                });
            },
            else => return self.evalLeafNode(root, cps, self.p.flags.ignore_case),
        }

        while (self.eval_stack.items().len > 0) {
            const eval_items = self.eval_stack.items();
            const top_idx = eval_items.len - 1;
            const frame = &eval_items[top_idx];
            const comp = self.p.class_nodes[frame.node_idx].compound;
            if (frame.child_pos < comp.len) {
                const child_idx = comp.start + frame.child_pos;
                frame.child_pos += 1;
                const child = self.p.class_nodes[child_idx];
                switch (child) {
                    .compound => |cc| {
                        try self.eval_stack.append(self.gpa, .{
                            .node_idx = child_idx,
                            .child_pos = 0,
                            .acc = (cc.op == .intersection_op),
                            .ignore_case = cc.ignore_case,
                        });
                    },
                    else => {
                        const res = self.evalLeafNode(child, cps, frame.ignore_case);
                        combine(frame, comp.op, res, comp.len);
                    },
                }
            } else {
                const finished = self.eval_stack.pop().?;
                const res = if (comp.inverted) !finished.acc else finished.acc;
                const rem = self.eval_stack.items();
                if (rem.len == 0) return res;
                const parent = &rem[rem.len - 1];
                const parent_comp = self.p.class_nodes[parent.node_idx].compound;
                combine(parent, parent_comp.op, res, parent_comp.len);
            }
        }
        unreachable;
    }

    fn isWordAt(self: *const Matcher, pos: u32, unicode_icase: bool) bool {
        if (pos >= self.input.len) return false;
        return isWordChar(self.input[pos], unicode_icase);
    }

    const DecodedCp = struct {
        cp: u21,
        next_idx: u32,
    };

    fn readCodePointAt(self: *const Matcher, idx: u32, rev: bool) ?DecodedCp {
        if (!self.p.flags.isUnicodeMode()) {
            if (rev) {
                return if (idx > 0) .{ .cp = self.input[idx - 1], .next_idx = idx - 1 } else null;
            }
            return if (idx < self.input.len) .{ .cp = self.input[idx], .next_idx = idx + 1 } else null;
        }
        if (rev) {
            if (idx == 0) return null;
            const c1 = self.input[idx - 1];
            if (isTrailSurrogate(c1) and idx >= 2 and isLeadSurrogate(self.input[idx - 2])) {
                return .{ .cp = combineSurrogates(self.input[idx - 2], c1), .next_idx = idx - 2 };
            }
            return .{ .cp = c1, .next_idx = idx - 1 };
        }
        if (idx >= self.input.len) return null;
        const c0 = self.input[idx];
        if (isLeadSurrogate(c0) and idx + 1 < self.input.len and isTrailSurrogate(self.input[idx + 1])) {
            return .{ .cp = combineSurrogates(c0, self.input[idx + 1]), .next_idx = idx + 2 };
        }
        return .{ .cp = c0, .next_idx = idx + 1 };
    }

    fn readCodePoint(self: *const Matcher, idx: u32) ?DecodedCp {
        return self.readCodePointAt(idx, self.reverse);
    }

    fn matchBackref(self: *const Matcher, cap_num: u16, icase: bool, idx: u32) ?u32 {
        const slot = (@as(usize, cap_num) - 1) * 2;
        const c_start = self.caps[slot];
        const c_end = self.caps[slot + 1];
        if (c_start == unset_pos or c_end == unset_pos) {
            // Unset capture group always succeeds matching empty string.
            return idx;
        }
        const len = c_end - c_start;
        if (!icase or !self.p.flags.isUnicodeMode()) {
            const ref_slice = self.input[c_start..c_end];
            const cur_slice = if (self.reverse) blk: {
                if (idx < len) return null;
                break :blk self.input[idx - len .. idx];
            } else blk: {
                if (idx + len > self.input.len) return null;
                break :blk self.input[idx..][0..len];
            };
            if (icase) {
                for (ref_slice, cur_slice) |a, b| {
                    if (unicode.canonicalizeLegacy(a) != unicode.canonicalizeLegacy(b)) return null;
                }
            } else {
                if (!std.mem.eql(u16, ref_slice, cur_slice)) return null;
            }
            return if (self.reverse) idx - len else idx + len;
        }
        // Unicode mode with ignore_case: compare code-point by code-point.
        if (self.reverse) {
            var r_pos = c_end;
            var cur = idx;
            while (r_pos > c_start) {
                const ref_cp = self.readCodePointAt(r_pos, true) orelse return null;
                const cur_cp = self.readCodePointAt(cur, true) orelse return null;
                if (!self.matchesIcase(ref_cp.cp, cur_cp.cp)) return null;
                r_pos = ref_cp.next_idx;
                cur = cur_cp.next_idx;
            }
            return cur;
        } else {
            var r_pos = c_start;
            var cur = idx;
            while (r_pos < c_end) {
                const ref_cp = self.readCodePointAt(r_pos, false) orelse return null;
                const cur_cp = self.readCodePointAt(cur, false) orelse return null;
                if (!self.matchesIcase(ref_cp.cp, cur_cp.cp)) return null;
                r_pos = ref_cp.next_idx;
                cur = cur_cp.next_idx;
            }
            return cur;
        }
    }

    fn runAt(self: *Matcher, start_idx: u32) ExecError!?u32 {
        @memset(self.caps, unset_pos);
        @memset(self.loops, .{});
        self.cap_pool.clearRetainingCapacity();
        self.loop_pool.clearRetainingCapacity();
        self.actions.clearRetainingCapacity();
        self.markers.clearRetainingCapacity();
        self.reverse = false;

        var pc: u32 = 0;
        var idx: u32 = start_idx;

        while (true) {
            try self.chargeStep();
            const inst = self.p.insts[pc];
            const advance: bool = switch (inst) {
                .match => return idx,
                .char => |expected| blk: {
                    if (self.readCodePoint(idx)) |d| {
                        if (d.cp == expected) {
                            idx = d.next_idx;
                            pc += 1;
                            break :blk true;
                        }
                    }
                    break :blk false;
                },
                .char_icase => |expected_canon| blk: {
                    if (self.readCodePoint(idx)) |d| {
                        if (self.canonicalize(d.cp) == expected_canon) {
                            idx = d.next_idx;
                            pc += 1;
                            break :blk true;
                        }
                    }
                    break :blk false;
                },
                .any => blk: {
                    if (self.readCodePoint(idx)) |d| {
                        if (!isLineTerminator(d.cp)) {
                            idx = d.next_idx;
                            pc += 1;
                            break :blk true;
                        }
                    }
                    break :blk false;
                },
                .any_dot_all => blk: {
                    if (self.readCodePoint(idx)) |d| {
                        idx = d.next_idx;
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .bol => blk: {
                    const ok = idx == 0;
                    if (ok) pc += 1;
                    break :blk ok;
                },
                .bol_multiline => blk: {
                    const ok = (idx == 0) or (idx > 0 and isLineTerminator(self.input[idx - 1]));
                    if (ok) pc += 1;
                    break :blk ok;
                },
                .eol => blk: {
                    const ok = idx == self.input.len;
                    if (ok) pc += 1;
                    break :blk ok;
                },
                .eol_multiline => blk: {
                    const ok = (idx == self.input.len) or (idx < self.input.len and isLineTerminator(self.input[idx]));
                    if (ok) pc += 1;
                    break :blk ok;
                },
                .word_boundary, .word_boundary_icase => blk: {
                    const u_icase = (inst == .word_boundary_icase);
                    const left = if (idx > 0) self.isWordAt(idx - 1, u_icase) else false;
                    const right = self.isWordAt(idx, u_icase);
                    if (left != right) {
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .not_word_boundary, .not_word_boundary_icase => blk: {
                    const u_icase = (inst == .not_word_boundary_icase);
                    const left = if (idx > 0) self.isWordAt(idx - 1, u_icase) else false;
                    const right = self.isWordAt(idx, u_icase);
                    if (left == right) {
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .builtin => |b| blk: {
                    if (self.readCodePoint(idx)) |d| {
                        if (matchesBuiltin(b.class, d.cp, b.unicode_icase)) {
                            idx = d.next_idx;
                            pc += 1;
                            break :blk true;
                        }
                    }
                    break :blk false;
                },
                .class => |c_idx| blk: {
                    const def = self.p.classes[c_idx];
                    if (!def.has_strings) {
                        if (self.readCodePoint(idx)) |d| {
                            if (try self.matchesClassSlice(def.root_node, &.{d.cp})) {
                                idx = d.next_idx;
                                pc += 1;
                                break :blk true;
                            }
                        }
                        break :blk false;
                    }
                    // v-mode class that may match strings (longest match first, backtrack to shorter).
                    var stack_cps: [64]u21 = undefined;
                    var stack_ends: [65]u32 = undefined;
                    const max_k = def.max_str_len;
                    const heap_cps = if (max_k > stack_cps.len) try self.gpa.alloc(u21, max_k) else null;
                    defer if (heap_cps) |h| self.gpa.free(h);
                    const heap_ends = if (max_k > stack_cps.len) try self.gpa.alloc(u32, max_k + 1) else null;
                    defer if (heap_ends) |h| self.gpa.free(h);

                    const cps_buf = if (heap_cps) |h| h else stack_cps[0..max_k];
                    const ends_buf = if (heap_ends) |h| h else stack_ends[0 .. max_k + 1];

                    ends_buf[0] = idx;
                    var decoded: usize = 0;
                    var cur = idx;
                    while (decoded < max_k) : (decoded += 1) {
                        const d = self.readCodePoint(cur) orelse break;
                        cps_buf[decoded] = d.cp;
                        cur = d.next_idx;
                        ends_buf[decoded + 1] = cur;
                    }
                    if (self.reverse and decoded > 1) {
                        std.mem.reverse(u21, cps_buf[0..decoded]);
                    }

                    var matched_any = false;
                    var longest_end: u32 = 0;
                    var k: usize = 0;
                    while (k <= decoded) : (k += 1) {
                        const slice = if (self.reverse)
                            cps_buf[decoded - k .. decoded]
                        else
                            cps_buf[0..k];
                        if (try self.matchesClassSlice(def.root_node, slice)) {
                            if (matched_any) {
                                try self.pushBranch(pc + 1, longest_end);
                            }
                            matched_any = true;
                            longest_end = ends_buf[k];
                        }
                    }
                    if (matched_any) {
                        idx = longest_end;
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .backref => |cap_num| blk: {
                    if (self.matchBackref(cap_num, false, idx)) |next_idx| {
                        idx = next_idx;
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .backref_icase => |cap_num| blk: {
                    if (self.matchBackref(cap_num, true, idx)) |next_idx| {
                        idx = next_idx;
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .save_start => |cap_num| blk: {
                    const slot = (@as(usize, cap_num) - 1) * 2;
                    self.caps[slot] = idx;
                    pc += 1;
                    break :blk true;
                },
                .save_end => |cap_num| blk: {
                    const slot = (@as(usize, cap_num) - 1) * 2;
                    self.caps[slot + 1] = idx;
                    pc += 1;
                    break :blk true;
                },
                .jump => |target| blk: {
                    pc = target;
                    break :blk true;
                },
                .split => |s| blk: {
                    try self.pushBranch(s.second, idx);
                    pc = s.first;
                    break :blk true;
                },
                .loop_init => |li| blk: {
                    self.loops[li.loop_id] = .{ .count = 0, .last_idx = unset_pos };
                    pc = li.step_pc;
                    break :blk true;
                },
                .loop_step => |ls| blk: {
                    const info = self.p.loops[ls.loop_id];
                    const st = self.loops[ls.loop_id];
                    // Optional iterations (when count > min) must have advanced `idx`;
                    // an empty optional iteration is rejected per ECMAScript RepeatMatcher.
                    if (st.count > info.min and st.last_idx == idx) {
                        break :blk false;
                    }
                    if (st.count < info.min) {
                        self.loops[ls.loop_id] = .{ .count = st.count + 1, .last_idx = idx };
                        self.clearCaptures(info.cap_start, info.cap_end);
                        pc = ls.body_pc;
                        break :blk true;
                    }
                    if (st.count == info.max) {
                        pc = ls.exit_pc;
                        break :blk true;
                    }
                    // Optional repetition: `min <= count < max`.
                    if (info.greedy) {
                        try self.pushBranch(ls.exit_pc, idx);
                        self.loops[ls.loop_id] = .{ .count = st.count + 1, .last_idx = idx };
                        self.clearCaptures(info.cap_start, info.cap_end);
                        pc = ls.body_pc;
                    } else {
                        // Lazy: try exiting first, push entering the body as backtrack branch.
                        const saved_count = st.count;
                        const saved_last = st.last_idx;
                        self.loops[ls.loop_id] = .{ .count = saved_count + 1, .last_idx = idx };
                        try self.pushBranch(ls.body_pc, idx);
                        // If we backtrack into `body_pc`, captures inside the atom must be cleared
                        // on that branch; clear them in the saved snapshot on `cap_pool`.
                        if (info.cap_start <= info.cap_end) {
                            const act_items = self.actions.items();
                            const last_act = act_items[act_items.len - 1].branch;
                            const start_slot = (@as(usize, info.cap_start) - 1) * 2;
                            const end_slot = @as(usize, info.cap_end) * 2;
                            @memset(self.cap_pool.items()[last_act.cap_base..][start_slot..end_slot], unset_pos);
                        }
                        self.loops[ls.loop_id] = .{ .count = saved_count, .last_idx = saved_last };
                        pc = ls.exit_pc;
                    }
                    break :blk true;
                },
                .lookahead => |la| blk: {
                    const action_wm: u32 = @intCast(self.actions.items().len);
                    const cap_wm: u32 = @intCast(self.cap_pool.items().len);
                    const loop_wm: u32 = @intCast(self.loop_pool.items().len);
                    if (la.negative) {
                        try self.actions.ensureUnusedCapacity(self.gpa, 1);
                        const snap = try self.pushSnapshot();
                        self.actions.appendAssumeCapacity(.{
                            .lookahead_neg_success = .{
                                .next_pc = la.next_pc,
                                .idx = idx,
                                .saved_reverse = self.reverse,
                                .cap_base = snap.cap_base,
                                .loop_base = snap.loop_base,
                            },
                        });
                    }
                    try self.markers.append(self.gpa, .{
                        .negative = la.negative,
                        .saved_reverse = self.reverse,
                        .next_pc = la.next_pc,
                        .saved_idx = idx,
                        .action_watermark = action_wm,
                        .cap_watermark = cap_wm,
                        .loop_watermark = loop_wm,
                    });
                    self.reverse = la.reverse;
                    pc = la.body_pc;
                    break :blk true;
                },
                .lookahead_done => blk: {
                    const m = self.markers.pop().?;
                    // Discard any backtrack choices created inside the lookahead body.
                    self.actions.shrinkRetainingCapacity(m.action_watermark);
                    self.cap_pool.shrinkRetainingCapacity(m.cap_watermark);
                    self.loop_pool.shrinkRetainingCapacity(m.loop_watermark);
                    self.reverse = m.saved_reverse;
                    if (m.negative) {
                        // Negative lookahead body matched -> the assertion fails!
                        break :blk false;
                    } else {
                        // Positive lookahead body matched -> commit captures, rewind idx, continue.
                        idx = m.saved_idx;
                        pc = m.next_pc;
                        break :blk true;
                    }
                },
            };

            if (!advance) {
                // Pop from explicit backtrack stack.
                if (self.actions.items().len == 0) return null;
                try self.chargeStep();
                const act = self.actions.pop().?;
                // Drop any lookahead markers whose watermark was above the popped action.
                const rem_actions = self.actions.items().len;
                while (self.markers.items().len > 0 and
                    self.markers.items()[self.markers.items().len - 1].action_watermark > rem_actions)
                {
                    _ = self.markers.pop();
                }
                switch (act) {
                    .branch => |b| {
                        self.restoreSnapshot(b.cap_base, b.loop_base);
                        self.reverse = b.reverse;
                        pc = b.pc;
                        idx = b.idx;
                    },
                    .lookahead_neg_success => |ns| {
                        // The negative lookahead body exhausted all branches without matching,
                        // so pop its marker, restore state before the lookahead, and continue!
                        _ = self.markers.pop();
                        self.restoreSnapshot(ns.cap_base, ns.loop_base);
                        self.reverse = ns.saved_reverse;
                        pc = ns.next_pc;
                        idx = ns.idx;
                    },
                }
            }
        }
    }
};

/// Match at `start` (sticky: only at `start`; otherwise scan forward). `captures.len` must be
/// `program.capture_count + 1`; `captures[0]` is the whole match; unmatched groups are null.
/// `steps` is a budget that every matcher step decrements; at 0 return `error.StepLimit`.
pub fn exec(
    gpa: Allocator,
    p: *const Program,
    input: []const u16,
    start: u32,
    steps: *u64,
    captures: []?Range,
) ExecError!bool {
    std.debug.assert(captures.len == @as(usize, p.capture_count) + 1);
    for (captures) |*c| c.* = null;

    if (start > input.len) return false;

    var stack_caps: [32]u32 = undefined;
    var stack_loops: [16]LoopState = undefined;
    const cap_slots = @as(usize, p.capture_count) * 2;
    const caps_heap = cap_slots > stack_caps.len;
    const caps_buf = if (caps_heap) try gpa.alloc(u32, cap_slots) else stack_caps[0..cap_slots];
    errdefer if (caps_heap) gpa.free(caps_buf);

    const loops_heap = p.loop_count > stack_loops.len;
    const loops_buf = if (loops_heap) try gpa.alloc(LoopState, p.loop_count) else stack_loops[0..p.loop_count];

    var matcher: Matcher = .{
        .gpa = gpa,
        .p = p,
        .input = input,
        .steps = steps,
        .caps = caps_buf,
        .caps_heap = caps_heap,
        .loops = loops_buf,
        .loops_heap = loops_heap,
    };
    defer matcher.deinit();

    var pos: u32 = start;
    const limit: u32 = if (p.flags.sticky) start else @intCast(input.len);
    while (pos <= limit) {
        if (try matcher.runAt(pos)) |end_idx| {
            captures[0] = .{ .start = pos, .end = end_idx };
            for (0..p.capture_count) |i| {
                const s = matcher.caps[i * 2];
                const e = matcher.caps[i * 2 + 1];
                if (s != unset_pos and e != unset_pos) {
                    captures[i + 1] = .{ .start = s, .end = e };
                } else {
                    captures[i + 1] = null;
                }
            }
            return true;
        }
        if (p.flags.isUnicodeMode() and pos + 1 < input.len and isLeadSurrogate(input[pos]) and isTrailSurrogate(input[pos + 1])) {
            pos += 2;
        } else {
            pos += 1;
        }
    }
    return false;
}
