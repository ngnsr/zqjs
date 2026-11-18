//! Standalone ECMAScript-style regular expression engine over UTF-16 code units.
//!
//! No native recursion in either the parser/compiler or the backtracking matcher:
//! compilation uses an explicit operator/group stack bounded by `max_depth`, and
//! execution uses an explicit heap stack bounded by the caller's step budget.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Maximum group/lookahead nesting depth during parsing. Prevents pathological patterns
/// from consuming excessive compile-time stack memory and satisfies the spec requirement.
pub const max_depth: u16 = 512;

/// Maximum number of compiled bytecode instructions in a single regex `Program`.
/// Quantifiers with finite bounds (`{n,m}`) are compiled using counted loop registers
/// rather than unrolling, so legitimate patterns stay well below this bound while huge
/// patterns fail cleanly with `error.TooComplex` instead of exhausting heap memory.
pub const max_program_insts: u32 = 65_536;

/// Maximum number of character-class range items across all `[...]` classes in a program.
/// Prevents a single pattern with thousands of ranges from growing unboundedly.
pub const max_class_items: u32 = 65_536;

/// Maximum number of loop counters (`{n,m}` / `*` / `+` / `?` repetitions) in a program.
pub const max_loops: u16 = 4_096;

/// Maximum number of capturing groups in a single pattern.
pub const max_captures: u16 = 4_096;

/// Maximum quantifier repetition bound (`{n,m}`). Exceeding this returns `error.TooComplex`.
pub const max_quantifier_bound: u32 = 65_535;

/// Index ceilings for the matcher's backtrack stack, not policy limits: a greedy loop
/// saves one state per iteration, so a small cap would reject `.*` over long input.
/// The caller's `steps` budget and allocator bound the real work and memory.
pub const max_backtrack_states: u32 = std.math.maxInt(u32) - 1;
pub const max_backtrack_cells: u32 = std.math.maxInt(u32) - @as(u32, max_captures) * 2;

pub const Flags = struct {
    ignore_case: bool = false,
    multiline: bool = false,
    dot_all: bool = false,
    sticky: bool = false,
};

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

const ClassItem = union(enum) {
    range: struct { lo: u16, hi: u16 },
    builtin: BuiltinClass,
};

const ClassDef = struct {
    inverted: bool,
    start: u32,
    len: u32,
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
    char: u16,
    char_icase: u16, // stored as ASCII uppercase
    any, // . (not LineTerminator)
    any_dot_all, // . with dot_all
    bol, // ^
    eol, // $
    word_boundary, // \b
    not_word_boundary, // \B
    builtin: BuiltinClass,
    class: u32, // index into Program.classes
    backref: u16, // 1..9
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
        body_pc: u32,
        next_pc: u32,
        cap_start: u16,
        cap_end: u16,
    },
    lookahead_done,
};

pub const Program = struct {
    insts: []Inst,
    classes: []ClassDef,
    class_items: []ClassItem,
    loops: []LoopInfo,
    capture_count: u16,
    loop_count: u16,
    flags: Flags,

    pub fn deinit(self: *Program, gpa: Allocator) void {
        gpa.free(self.insts);
        gpa.free(self.classes);
        gpa.free(self.class_items);
        gpa.free(self.loops);
        self.* = undefined;
    }
};

fn isAsciiDigit(c: u16) bool {
    return c >= '0' and c <= '9';
}

fn isAsciiWord(c: u16) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

fn isLineTerminator(c: u16) bool {
    return c == 0x000A or c == 0x000D or c == 0x2028 or c == 0x2029;
}

fn isWhiteSpaceOrLineTerminator(c: u16) bool {
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

fn matchesBuiltin(b: BuiltinClass, c: u16) bool {
    return switch (b) {
        .digit => isAsciiDigit(c),
        .not_digit => !isAsciiDigit(c),
        .word => isAsciiWord(c),
        .not_word => !isAsciiWord(c),
        .space => isWhiteSpaceOrLineTerminator(c),
        .not_space => !isWhiteSpaceOrLineTerminator(c),
    };
}

fn asciiUpper(c: u16) u16 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

fn hexDigit(c: u16) ?u16 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn isSyntaxCharacter(c: u16) bool {
    return switch (c) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|' => true,
        else => false,
    };
}

const GroupKind = enum {
    capturing,
    non_capturing,
    pos_lookahead,
    neg_lookahead,
};

const GroupFrame = struct {
    kind: GroupKind,
    capture_index: u16,
    cap_before: u16,
    term_start_pc: u32,
    branch_start_pc: u32,
    /// Fixup list of `jump` instructions at the end of finished branches in this group.
    end_jumps: std.ArrayList(u32) = .empty,
    /// PC of the `lookahead` instruction if `kind` is lookahead.
    lookahead_pc: u32 = 0,
};

const LastAtom = struct {
    start_pc: u32,
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
    diag: *Diagnostic,
    total_captures: u16 = 0,
    next_capture: u16 = 0,

    insts: std.ArrayList(Inst) = .empty,
    classes: std.ArrayList(ClassDef) = .empty,
    class_items: std.ArrayList(ClassItem) = .empty,
    loops: std.ArrayList(LoopInfo) = .empty,
    groups: std.ArrayList(GroupFrame) = .empty,

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
        self.class_items.deinit(self.gpa);
        self.loops.deinit(self.gpa);
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
        self.diag.* = .{ .message = msg, .feature = null };
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
            if (g.lookahead_pc >= at and (g.kind == .pos_lookahead or g.kind == .neg_lookahead)) {
                g.lookahead_pc += 1;
            }
        }
    }

    /// Pre-pass to count capturing groups so `\N` can be validated against total captures
    /// before emitting instructions.
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
                    // (?...) is not a plain capturing group; named groups (?<name>...)
                    // are rejected as Unsupported during the main parse.
                } else {
                    count += 1;
                    if (count > max_captures) return self.failComplex("too many capturing groups");
                }
            }
            i += 1;
        }
        return @intCast(count);
    }

    fn emitLiteral(self: *Compiler, c: u16) CompileError!void {
        if (self.flags.ignore_case and c > 0x7F) {
            return self.failUnsupported("regex_ignore_case_unicode", "non-ASCII character with ignore_case flag");
        }
        const start_pc: u32 = @intCast(self.insts.items.len);
        if (self.flags.ignore_case) {
            _ = try self.emit(.{ .char_icase = asciiUpper(c) });
        } else {
            _ = try self.emit(.{ .char = c });
        }
        self.last_atom = .{
            .start_pc = start_pc,
            .cap_start = self.next_capture + 1,
            .cap_end = self.next_capture,
            .quantifiable = true,
            .is_lookahead = false,
        };
    }

    fn parseHexEscape(self: *Compiler, digits: usize) CompileError!u16 {
        if (self.pos + digits > self.pattern.len) {
            return self.failUnsupported("regex_annex_b", "malformed hex or unicode escape");
        }
        var val: u16 = 0;
        for (0..digits) |k| {
            const d = hexDigit(self.pattern[self.pos + k]) orelse
                return self.failUnsupported("regex_annex_b", "malformed hex or unicode escape");
            val = (val << 4) | d;
        }
        self.pos += digits;
        return val;
    }

    const ClassAtom = union(enum) {
        single: u16,
        builtin: BuiltinClass,
    };

    fn parseClassAtom(self: *Compiler) CompileError!ClassAtom {
        const c = self.pattern[self.pos];
        self.pos += 1;
        if (c != '\\') return .{ .single = c };
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
            'B' => return self.failUnsupported("regex_annex_b", "\\B inside character class"),
            'n' => return .{ .single = '\n' },
            'r' => return .{ .single = '\r' },
            't' => return .{ .single = '\t' },
            'f' => return .{ .single = 0x000C },
            'v' => return .{ .single = 0x000B },
            '0' => {
                if (self.pos < self.pattern.len and isAsciiDigit(self.pattern[self.pos])) {
                    return self.failUnsupported("regex_annex_b", "legacy octal escape in character class");
                }
                return .{ .single = 0 };
            },
            '1'...'9' => return self.failUnsupported("regex_annex_b", "decimal/octal escape in character class"),
            'x' => return .{ .single = try self.parseHexEscape(2) },
            'u' => {
                if (self.pos < self.pattern.len and self.pattern[self.pos] == '{') {
                    return self.failUnsupported("regex_unicode_escape_braced", "\\u{...} escape requires unicode mode");
                }
                return .{ .single = try self.parseHexEscape(4) };
            },
            'c' => return self.failUnsupported("regex_control_escape", "\\c control escape is not supported"),
            'p', 'P' => return self.failUnsupported("regex_unicode_property", "unicode property escapes are not supported"),
            'k' => return self.failUnsupported("regex_named_groups", "named backreferences are not supported"),
            else => {
                if (isSyntaxCharacter(esc) or esc == '/' or esc == '-') {
                    return .{ .single = esc };
                }
                if ((esc >= 'a' and esc <= 'z') or (esc >= 'A' and esc <= 'Z')) {
                    return self.failUnsupported("regex_annex_b", "annex B letter identity escape");
                }
                return .{ .single = esc };
            },
        }
    }

    fn addClassRange(self: *Compiler, lo: u16, hi: u16) CompileError!void {
        if (self.class_items.items.len >= max_class_items) {
            return self.failComplex("too many character class items");
        }
        try self.class_items.append(self.gpa, .{ .range = .{ .lo = lo, .hi = hi } });
    }

    fn addClassRangeFolded(self: *Compiler, lo: u16, hi: u16) CompileError!void {
        if (self.flags.ignore_case and (lo > 0x7F or hi > 0x7F)) {
            return self.failUnsupported("regex_ignore_case_unicode", "non-ASCII character or range in class with ignore_case flag");
        }
        if (!self.flags.ignore_case) {
            try self.addClassRange(lo, hi);
            return;
        }
        if (hi < 'a' or lo > 'z') {
            try self.addClassRange(lo, hi);
            return;
        }
        if (lo < 'a') {
            try self.addClassRange(lo, 'a' - 1);
        }
        const lower_lo = @max(lo, @as(u16, 'a'));
        const lower_hi = @min(hi, @as(u16, 'z'));
        try self.addClassRange(lower_lo - 32, lower_hi - 32);
        if (hi > 'z') {
            try self.addClassRange('z' + 1, hi);
        }
    }

    fn parseClass(self: *Compiler) CompileError!void {
        var inverted = false;
        if (self.pos < self.pattern.len and self.pattern[self.pos] == '^') {
            inverted = true;
            self.pos += 1;
        }
        const items_start: u32 = @intCast(self.class_items.items.len);
        while (self.pos < self.pattern.len and self.pattern[self.pos] != ']') {
            const first = try self.parseClassAtom();
            if (self.pos < self.pattern.len and self.pattern[self.pos] == '-') {
                if (self.pos + 1 < self.pattern.len and self.pattern[self.pos + 1] == ']') {
                    // Trailing `-` before `]` is a literal `-`.
                    switch (first) {
                        .single => |ch| try self.addClassRangeFolded(ch, ch),
                        .builtin => |b| {
                            if (self.class_items.items.len >= max_class_items) return self.failComplex("too many character class items");
                            try self.class_items.append(self.gpa, .{ .builtin = b });
                        },
                    }
                    self.pos += 1;
                    try self.addClassRangeFolded('-', '-');
                    break;
                }
                self.pos += 1; // consume '-'
                const second = try self.parseClassAtom();
                if (first == .builtin or second == .builtin) {
                    return self.failUnsupported("regex_annex_b", "character class range with character class escape");
                }
                const lo = first.single;
                const hi = second.single;
                if (lo > hi) {
                    return self.failSyntax("character class range out of order");
                }
                try self.addClassRangeFolded(lo, hi);
            } else {
                switch (first) {
                    .single => |ch| try self.addClassRangeFolded(ch, ch),
                    .builtin => |b| {
                        if (self.class_items.items.len >= max_class_items) return self.failComplex("too many character class items");
                        try self.class_items.append(self.gpa, .{ .builtin = b });
                    },
                }
            }
        }
        if (self.pos >= self.pattern.len or self.pattern[self.pos] != ']') {
            return self.failSyntax("unterminated character class");
        }
        self.pos += 1; // consume ']'

        const items_len: u32 = @intCast(self.class_items.items.len - items_start);
        const class_idx: u32 = @intCast(self.classes.items.len);
        try self.classes.append(self.gpa, .{
            .inverted = inverted,
            .start = items_start,
            .len = items_len,
        });
        const start_pc = try self.emit(.{ .class = class_idx });
        self.last_atom = .{
            .start_pc = start_pc,
            .cap_start = self.next_capture + 1,
            .cap_end = self.next_capture,
            .quantifiable = true,
            .is_lookahead = false,
        };
    }

    fn parseAtomEscape(self: *Compiler) CompileError!void {
        if (self.pos >= self.pattern.len) return self.failSyntax("escape at end of pattern");
        const esc = self.pattern[self.pos];
        self.pos += 1;
        switch (esc) {
            'b' => {
                const pc = try self.emit(.word_boundary);
                self.last_atom = .{ .start_pc = pc, .cap_start = 1, .cap_end = 0, .quantifiable = false, .is_lookahead = false };
            },
            'B' => {
                const pc = try self.emit(.not_word_boundary);
                self.last_atom = .{ .start_pc = pc, .cap_start = 1, .cap_end = 0, .quantifiable = false, .is_lookahead = false };
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
                    return self.failUnsupported("regex_annex_b", "legacy octal escape");
                }
                try self.emitLiteral(0);
            },
            '1'...'9' => {
                var num: u32 = esc - '0';
                if (self.pos < self.pattern.len and isAsciiDigit(self.pattern[self.pos])) {
                    while (self.pos < self.pattern.len and isAsciiDigit(self.pattern[self.pos])) {
                        num = num *| 10 +| (self.pattern[self.pos] - '0');
                        self.pos += 1;
                    }
                    if (num <= self.total_captures) {
                        return self.failUnsupported("regex_backref_gt9", "backreferences above \\9 are not supported");
                    }
                    return self.failUnsupported("regex_annex_b", "decimal or octal escape exceeding capture count");
                }
                if (num > self.total_captures) {
                    return self.failUnsupported("regex_annex_b", "backreference exceeds number of capturing groups");
                }
                const start_pc = try self.emit(.{ .backref = @intCast(num) });
                self.last_atom = .{
                    .start_pc = start_pc,
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
                if (self.pos < self.pattern.len and self.pattern[self.pos] == '{') {
                    return self.failUnsupported("regex_unicode_escape_braced", "\\u{...} escape requires unicode mode");
                }
                const c = try self.parseHexEscape(4);
                try self.emitLiteral(c);
            },
            'c' => return self.failUnsupported("regex_control_escape", "\\c control escape is not supported"),
            'p', 'P' => return self.failUnsupported("regex_unicode_property", "unicode property escapes are not supported"),
            'k' => return self.failUnsupported("regex_named_groups", "named backreferences are not supported"),
            else => {
                if (isSyntaxCharacter(esc) or esc == '/') {
                    try self.emitLiteral(esc);
                } else if ((esc >= 'a' and esc <= 'z') or (esc >= 'A' and esc <= 'Z')) {
                    return self.failUnsupported("regex_annex_b", "annex B letter identity escape");
                } else {
                    try self.emitLiteral(esc);
                }
            },
        }
    }

    fn emitBuiltinAtom(self: *Compiler, b: BuiltinClass) CompileError!void {
        const start_pc = try self.emit(.{ .builtin = b });
        self.last_atom = .{
            .start_pc = start_pc,
            .cap_start = self.next_capture + 1,
            .cap_end = self.next_capture,
            .quantifiable = true,
            .is_lookahead = false,
        };
    }

    fn openGroup(self: *Compiler) CompileError!void {
        if (self.groups.items.len >= max_depth) {
            return self.failComplex("regex nesting exceeds max_depth");
        }
        var kind: GroupKind = .capturing;
        var cap_idx: u16 = 0;
        const cap_before = self.next_capture;

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
                    if (self.pos < self.pattern.len and (self.pattern[self.pos] == '=' or self.pattern[self.pos] == '!')) {
                        return self.failUnsupported("regex_lookbehind", "lookbehind assertions are not supported");
                    }
                    return self.failUnsupported("regex_named_groups", "named capturing groups are not supported");
                },
                'i', 'm', 's', '-' => return self.failUnsupported("regex_modifiers", "inline flag modifiers are not supported"),
                else => return self.failSyntax("invalid group modifier"),
            }
        } else {
            self.next_capture += 1;
            cap_idx = self.next_capture;
        }

        const term_start_pc: u32 = @intCast(self.insts.items.len);
        var lookahead_pc: u32 = 0;
        switch (kind) {
            .capturing => _ = try self.emit(.{ .save_start = cap_idx }),
            .non_capturing => {},
            .pos_lookahead, .neg_lookahead => {
                lookahead_pc = try self.emit(.{
                    .lookahead = .{
                        .negative = (kind == .neg_lookahead),
                        .body_pc = term_start_pc + 1,
                        .next_pc = 0, // patched on closeGroup
                        .cap_start = cap_before + 1,
                        .cap_end = cap_before,
                    },
                });
            },
        }
        const branch_start_pc: u32 = @intCast(self.insts.items.len);

        try self.groups.append(self.gpa, .{
            .kind = kind,
            .capture_index = cap_idx,
            .cap_before = cap_before,
            .term_start_pc = term_start_pc,
            .branch_start_pc = branch_start_pc,
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

        switch (g.kind) {
            .capturing => {
                _ = try self.emit(.{ .save_end = g.capture_index });
                self.last_atom = .{
                    .start_pc = g.term_start_pc,
                    .cap_start = g.cap_before + 1,
                    .cap_end = self.next_capture,
                    .quantifiable = true,
                    .is_lookahead = false,
                };
            },
            .non_capturing => {
                self.last_atom = .{
                    .start_pc = g.term_start_pc,
                    .cap_start = g.cap_before + 1,
                    .cap_end = self.next_capture,
                    .quantifiable = true,
                    .is_lookahead = false,
                };
            },
            .pos_lookahead, .neg_lookahead => {
                const done_pc = try self.emit(.lookahead_done);
                self.insts.items[g.lookahead_pc].lookahead.next_pc = done_pc + 1;
                self.insts.items[g.lookahead_pc].lookahead.cap_start = g.cap_before + 1;
                self.insts.items[g.lookahead_pc].lookahead.cap_end = self.next_capture;
                self.last_atom = .{
                    .start_pc = g.term_start_pc,
                    .cap_start = g.cap_before + 1,
                    .cap_end = self.next_capture,
                    .quantifiable = false,
                    .is_lookahead = true,
                };
            },
        }
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
            return self.failUnsupported("regex_annex_b", "quantifier on lookahead assertion");
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
        const step_pc = try self.emit(.{
            .loop_step = .{
                .loop_id = loop_id,
                .body_pc = atom.start_pc + 1,
                .exit_pc = @intCast(self.insts.items.len + 1),
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
                    const pc = try self.emit(.bol);
                    self.last_atom = .{ .start_pc = pc, .cap_start = 1, .cap_end = 0, .quantifiable = false, .is_lookahead = false };
                },
                '$' => {
                    const pc = try self.emit(.eol);
                    self.last_atom = .{ .start_pc = pc, .cap_start = 1, .cap_end = 0, .quantifiable = false, .is_lookahead = false };
                },
                '.' => {
                    const pc = try self.emit(if (self.flags.dot_all) .any_dot_all else .any);
                    self.last_atom = .{
                        .start_pc = pc,
                        .cap_start = self.next_capture + 1,
                        .cap_end = self.next_capture,
                        .quantifiable = true,
                        .is_lookahead = false,
                    };
                },
                '\\' => try self.parseAtomEscape(),
                '[' => try self.parseClass(),
                ']' => return self.failUnsupported("regex_annex_b", "unescaped ']' outside character class"),
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
                        return self.failUnsupported("regex_annex_b", "unescaped '{' that does not form a quantifier");
                    }
                },
                '}' => return self.failUnsupported("regex_annex_b", "unescaped '}' outside quantifier"),
                else => try self.emitLiteral(c),
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
        const class_items = try self.class_items.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(class_items);
        const loops = try self.loops.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(loops);

        return .{
            .insts = insts,
            .classes = classes,
            .class_items = class_items,
            .loops = loops,
            .capture_count = self.total_captures,
            .loop_count = @intCast(loops.len),
            .flags = self.flags,
        };
    }
};

pub fn compile(gpa: Allocator, pattern: []const u16, flags: Flags, diag: *Diagnostic) CompileError!Program {
    diag.* = .{};
    var compiler: Compiler = .{
        .gpa = gpa,
        .pattern = pattern,
        .flags = flags,
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
        cap_base: u32,
        loop_base: u32,
    },
    lookahead_neg_success: struct {
        next_pc: u32,
        idx: u32,
        cap_base: u32,
        loop_base: u32,
    },
};

const LookaheadMarker = struct {
    negative: bool,
    next_pc: u32,
    saved_idx: u32,
    action_watermark: u32,
    cap_watermark: u32,
    loop_watermark: u32,
};

const Matcher = struct {
    gpa: Allocator,
    p: *const Program,
    input: []const u16,
    steps: *u64,

    /// Current capture slots: 2 slots (start, end) per capture index `1..capture_count`.
    /// Index `2 * (cap - 1)` is start, `2 * (cap - 1) + 1` is end.
    caps: []u32,
    /// Current loop counter states: 1 per `0..loop_count`.
    loops: []LoopState,

    /// Flat pools storing snapshots of `caps` and `loops` pushed onto `actions`.
    cap_pool: std.ArrayList(u32) = .empty,
    loop_pool: std.ArrayList(LoopState) = .empty,
    actions: std.ArrayList(Action) = .empty,
    markers: std.ArrayList(LookaheadMarker) = .empty,

    fn deinit(self: *Matcher) void {
        self.cap_pool.deinit(self.gpa);
        self.loop_pool.deinit(self.gpa);
        self.actions.deinit(self.gpa);
        self.markers.deinit(self.gpa);
        self.gpa.free(self.caps);
        self.gpa.free(self.loops);
    }

    fn chargeStep(self: *Matcher) ExecError!void {
        if (self.steps.* == 0) return error.StepLimit;
        self.steps.* -= 1;
    }

    fn pushSnapshot(self: *Matcher) ExecError!struct { cap_base: u32, loop_base: u32 } {
        // Saved states are bounded by the step budget (each comes from a charged
        // instruction) and memory by the allocator; this only keeps u32 indices valid.
        if (self.actions.items.len >= max_backtrack_states or
            self.cap_pool.items.len + self.caps.len > max_backtrack_cells or
            self.loop_pool.items.len + self.loops.len > max_backtrack_cells)
        {
            return error.OutOfMemory;
        }
        const cap_base: u32 = @intCast(self.cap_pool.items.len);
        try self.cap_pool.appendSlice(self.gpa, self.caps);
        errdefer self.cap_pool.shrinkRetainingCapacity(cap_base);
        const loop_base: u32 = @intCast(self.loop_pool.items.len);
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
                .cap_base = snap.cap_base,
                .loop_base = snap.loop_base,
            },
        });
    }

    fn restoreSnapshot(self: *Matcher, cap_base: u32, loop_base: u32) void {
        @memcpy(self.caps, self.cap_pool.items[cap_base..][0..self.caps.len]);
        @memcpy(self.loops, self.loop_pool.items[loop_base..][0..self.loops.len]);
        self.cap_pool.shrinkRetainingCapacity(cap_base);
        self.loop_pool.shrinkRetainingCapacity(loop_base);
    }

    fn clearCaptures(self: *Matcher, cap_start: u16, cap_end: u16) void {
        if (cap_start > cap_end) return;
        const start_slot = (@as(usize, cap_start) - 1) * 2;
        const end_slot = @as(usize, cap_end) * 2;
        @memset(self.caps[start_slot..end_slot], unset_pos);
    }

    fn matchesClass(self: *const Matcher, class_idx: u32, raw_c: u16) bool {
        const def = self.p.classes[class_idx];
        const c = if (self.p.flags.ignore_case) asciiUpper(raw_c) else raw_c;
        const items = self.p.class_items[def.start..][0..def.len];
        var matched = false;
        for (items) |item| {
            switch (item) {
                .range => |r| {
                    if (c >= r.lo and c <= r.hi) {
                        matched = true;
                        break;
                    }
                },
                .builtin => |b| {
                    if (matchesBuiltin(b, raw_c)) {
                        matched = true;
                        break;
                    }
                },
            }
        }
        return if (def.inverted) !matched else matched;
    }

    fn isWordAt(self: *const Matcher, pos: u32) bool {
        if (pos >= self.input.len) return false;
        return isAsciiWord(self.input[pos]);
    }

    fn runAt(self: *Matcher, start_idx: u32) ExecError!?u32 {
        @memset(self.caps, unset_pos);
        @memset(self.loops, .{});
        self.cap_pool.clearRetainingCapacity();
        self.loop_pool.clearRetainingCapacity();
        self.actions.clearRetainingCapacity();
        self.markers.clearRetainingCapacity();

        var pc: u32 = 0;
        var idx: u32 = start_idx;

        while (true) {
            try self.chargeStep();
            const inst = self.p.insts[pc];
            const advance: bool = switch (inst) {
                .match => return idx,
                .char => |expected| blk: {
                    if (idx < self.input.len and self.input[idx] == expected) {
                        idx += 1;
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .char_icase => |expected_upper| blk: {
                    if (idx < self.input.len and asciiUpper(self.input[idx]) == expected_upper) {
                        idx += 1;
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .any => blk: {
                    if (idx < self.input.len and !isLineTerminator(self.input[idx])) {
                        idx += 1;
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .any_dot_all => blk: {
                    if (idx < self.input.len) {
                        idx += 1;
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .bol => blk: {
                    const ok = (idx == 0) or (self.p.flags.multiline and idx > 0 and isLineTerminator(self.input[idx - 1]));
                    if (ok) pc += 1;
                    break :blk ok;
                },
                .eol => blk: {
                    const ok = (idx == self.input.len) or (self.p.flags.multiline and idx < self.input.len and isLineTerminator(self.input[idx]));
                    if (ok) pc += 1;
                    break :blk ok;
                },
                .word_boundary => blk: {
                    const left = if (idx > 0) self.isWordAt(idx - 1) else false;
                    const right = self.isWordAt(idx);
                    if (left != right) {
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .not_word_boundary => blk: {
                    const left = if (idx > 0) self.isWordAt(idx - 1) else false;
                    const right = self.isWordAt(idx);
                    if (left == right) {
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .builtin => |b| blk: {
                    if (idx < self.input.len and matchesBuiltin(b, self.input[idx])) {
                        idx += 1;
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .class => |c_idx| blk: {
                    if (idx < self.input.len and self.matchesClass(c_idx, self.input[idx])) {
                        idx += 1;
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .backref => |cap_num| blk: {
                    const slot = (@as(usize, cap_num) - 1) * 2;
                    const c_start = self.caps[slot];
                    const c_end = self.caps[slot + 1];
                    if (c_start == unset_pos or c_end == unset_pos) {
                        // Unset capture group always succeeds matching empty string.
                        pc += 1;
                        break :blk true;
                    }
                    const len = c_end - c_start;
                    if (idx + len > self.input.len) break :blk false;
                    const ref_slice = self.input[c_start..c_end];
                    const cur_slice = self.input[idx..][0..len];
                    if (self.p.flags.ignore_case) {
                        var match_ok = true;
                        for (ref_slice, cur_slice) |a, b| {
                            if (asciiUpper(a) != asciiUpper(b)) {
                                match_ok = false;
                                break;
                            }
                        }
                        if (!match_ok) break :blk false;
                    } else {
                        if (!std.mem.eql(u16, ref_slice, cur_slice)) break :blk false;
                    }
                    idx += len;
                    pc += 1;
                    break :blk true;
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
                            const last_act = self.actions.items[self.actions.items.len - 1].branch;
                            const start_slot = (@as(usize, info.cap_start) - 1) * 2;
                            const end_slot = @as(usize, info.cap_end) * 2;
                            @memset(self.cap_pool.items[last_act.cap_base..][start_slot..end_slot], unset_pos);
                        }
                        self.loops[ls.loop_id] = .{ .count = saved_count, .last_idx = saved_last };
                        pc = ls.exit_pc;
                    }
                    break :blk true;
                },
                .lookahead => |la| blk: {
                    const action_wm: u32 = @intCast(self.actions.items.len);
                    const cap_wm: u32 = @intCast(self.cap_pool.items.len);
                    const loop_wm: u32 = @intCast(self.loop_pool.items.len);
                    if (la.negative) {
                        try self.actions.ensureUnusedCapacity(self.gpa, 1);
                        const snap = try self.pushSnapshot();
                        self.actions.appendAssumeCapacity(.{
                            .lookahead_neg_success = .{
                                .next_pc = la.next_pc,
                                .idx = idx,
                                .cap_base = snap.cap_base,
                                .loop_base = snap.loop_base,
                            },
                        });
                    }
                    try self.markers.append(self.gpa, .{
                        .negative = la.negative,
                        .next_pc = la.next_pc,
                        .saved_idx = idx,
                        .action_watermark = action_wm,
                        .cap_watermark = cap_wm,
                        .loop_watermark = loop_wm,
                    });
                    pc = la.body_pc;
                    break :blk true;
                },
                .lookahead_done => blk: {
                    const m = self.markers.pop().?;
                    // Discard any backtrack choices created inside the lookahead body.
                    self.actions.shrinkRetainingCapacity(m.action_watermark);
                    self.cap_pool.shrinkRetainingCapacity(m.cap_watermark);
                    self.loop_pool.shrinkRetainingCapacity(m.loop_watermark);
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
                if (self.actions.items.len == 0) return null;
                try self.chargeStep();
                const act = self.actions.pop().?;
                // Drop any lookahead markers whose watermark was above the popped action.
                while (self.markers.items.len > 0 and
                    self.markers.items[self.markers.items.len - 1].action_watermark > self.actions.items.len)
                {
                    _ = self.markers.pop();
                }
                switch (act) {
                    .branch => |b| {
                        self.restoreSnapshot(b.cap_base, b.loop_base);
                        pc = b.pc;
                        idx = b.idx;
                    },
                    .lookahead_neg_success => |ns| {
                        // The negative lookahead body exhausted all branches without matching,
                        // so pop its marker, restore state before the lookahead, and continue!
                        _ = self.markers.pop();
                        self.restoreSnapshot(ns.cap_base, ns.loop_base);
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

    const caps_buf = try gpa.alloc(u32, @as(usize, p.capture_count) * 2);
    const loops_buf = gpa.alloc(LoopState, p.loop_count) catch |err| {
        gpa.free(caps_buf);
        return err;
    };

    var matcher: Matcher = .{
        .gpa = gpa,
        .p = p,
        .input = input,
        .steps = steps,
        .caps = caps_buf,
        .loops = loops_buf,
    };
    defer matcher.deinit();

    var pos: u32 = start;
    const limit: u32 = if (p.flags.sticky) start else @intCast(input.len);
    while (pos <= limit) : (pos += 1) {
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
    }
    return false;
}
