//! Pure-Zig POSIX raw-mode line editor with UTF-8 editing, persistent history,
//! Ctrl-R reverse incremental search, Tab completion, live syntax highlighting,
//! and piped non-TTY fallback (D71).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const posix = std.posix;
const complete = @import("complete.zig");

pub const ReadResult = union(enum) {
    line: []const u8,
    eof,
    interrupt,
};

pub const ByteReader = struct {
    ctx: *anyopaque,
    read_byte: *const fn (ctx: *anyopaque) anyerror!?u8,
};

pub const CompleteFn = *const fn (ctx: *anyopaque, line: []const u8, cursor: usize, gpa: Allocator) Allocator.Error!complete.CompletionResult;
pub const HighlightFn = *const fn (line: []const u8, w: *Writer) Writer.Error!void;

pub const EditorConfig = struct {
    color: bool = false,
    history_path: ?[]const u8 = null,
    io: ?std.Io = null,
    complete_ctx: ?*anyopaque = null,
    complete_fn: ?CompleteFn = null,
    highlight_fn: ?HighlightFn = null,
};

var saved_termios_fd: ?posix.fd_t = null;
var saved_termios: posix.termios = undefined;

fn restoreTermiosSignalHandler(_: posix.SIG) callconv(.c) void {
    if (saved_termios_fd) |fd| {
        posix.tcsetattr(fd, .FLUSH, saved_termios) catch {};
    }
    std.process.exit(130);
}

pub const LineEditor = struct {
    gpa: Allocator,
    config: EditorConfig,
    history: std.ArrayList([]const u8) = .empty,
    max_history: usize = 1000,
    consecutive_ctrl_c: u32 = 0,
    /// Temporary buffer holding the last completed line (owned by LineEditor).
    last_line: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator, config: EditorConfig) LineEditor {
        return .{
            .gpa = gpa,
            .config = config,
        };
    }

    pub fn deinit(ed: *LineEditor) void {
        for (ed.history.items) |h| ed.gpa.free(h);
        ed.history.deinit(ed.gpa);
        ed.last_line.deinit(ed.gpa);
        ed.* = undefined;
    }

    pub fn addHistory(ed: *LineEditor, line: []const u8) Allocator.Error!void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;
        if (ed.history.items.len > 0 and std.mem.eql(u8, ed.history.items[ed.history.items.len - 1], line)) {
            return;
        }
        if (ed.history.items.len >= ed.max_history) {
            ed.gpa.free(ed.history.orderedRemove(0));
        }
        try ed.history.append(ed.gpa, try ed.gpa.dupe(u8, line));
    }

    pub fn loadHistory(ed: *LineEditor) void {
        const path = ed.config.history_path orelse return;
        const io = ed.config.io orelse return;
        if (path.len == 0) return;
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, ed.gpa, .limited(4 * 1024 * 1024)) catch return;
        defer ed.gpa.free(data);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) continue;
            ed.addHistory(line) catch break;
        }
    }

    pub fn saveHistory(ed: *const LineEditor) void {
        const path = ed.config.history_path orelse return;
        const io = ed.config.io orelse return;
        if (path.len == 0) return;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(ed.gpa);
        for (ed.history.items) |h| {
            buf.appendSlice(ed.gpa, h) catch return;
            buf.append(ed.gpa, '\n') catch return;
        }
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items }) catch {};
    }

    pub fn isTty() bool {
        var term: posix.termios = undefined;
        return posix.errno(posix.system.tcgetattr(posix.STDIN_FILENO, &term)) == .SUCCESS;
    }

    /// Reads one line from stdin (raw mode if TTY, plain line-by-line if piped).
    pub fn readLine(ed: *LineEditor, prompt: []const u8, out: *Writer) !ReadResult {
        if (!isTty()) {
            return ed.readPiped(out);
        }
        const fd = posix.STDIN_FILENO;
        const orig = try posix.tcgetattr(fd);
        saved_termios = orig;
        saved_termios_fd = fd;

        var raw = orig;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = true;
        raw.cflag.CSIZE = .CS8;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cc[@backingInt(posix.V.MIN)] = 1;
        raw.cc[@backingInt(posix.V.TIME)] = 0;

        try posix.tcsetattr(fd, .NOW, raw);
        defer {
            posix.tcsetattr(fd, .NOW, orig) catch {};
            saved_termios_fd = null;
        }

        const sa: posix.Sigaction = .{
            .handler = .{ .handler = restoreTermiosSignalHandler },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        var old_int: posix.Sigaction = undefined;
        var old_term: posix.Sigaction = undefined;
        posix.sigaction(posix.SIG.INT, &sa, &old_int);
        posix.sigaction(posix.SIG.TERM, &sa, &old_term);
        defer {
            posix.sigaction(posix.SIG.INT, &old_int, null);
            posix.sigaction(posix.SIG.TERM, &old_term, null);
        }

        var fd_reader: FdReader = .{ .fd = fd };
        return ed.readLineFromStream(prompt, fd_reader.interface(), out);
    }

    fn readPiped(ed: *LineEditor, _: *Writer) !ReadResult {
        var fd_reader: FdReader = .{ .fd = posix.STDIN_FILENO };
        return ed.readPipedFromStream(fd_reader.interface());
    }

    pub fn readPipedFromStream(ed: *LineEditor, reader: ByteReader) !ReadResult {
        ed.last_line.clearRetainingCapacity();
        while (true) {
            const b = try reader.read_byte(reader.ctx) orelse {
                if (ed.last_line.items.len == 0) return .eof;
                return .{ .line = ed.last_line.items };
            };
            if (b == '\n') {
                if (ed.last_line.items.len > 0 and ed.last_line.items[ed.last_line.items.len - 1] == '\r') {
                    _ = ed.last_line.pop();
                }
                return .{ .line = ed.last_line.items };
            }
            try ed.last_line.append(ed.gpa, b);
        }
    }

    /// Raw-mode interactive line editor driven by a `ByteReader` (used for both TTY and synthetic tests).
    pub fn readLineFromStream(ed: *LineEditor, prompt: []const u8, reader: ByteReader, out: *Writer) !ReadResult {
        ed.last_line.clearRetainingCapacity();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(ed.gpa);
        var draft: std.ArrayList(u8) = .empty;
        defer draft.deinit(ed.gpa);

        var cursor: usize = 0;
        var hist_idx: usize = ed.history.items.len;
        var browsing_history = false;

        try ed.refreshLine(prompt, buf.items, cursor, out);

        while (true) {
            const b = try reader.read_byte(reader.ctx) orelse {
                if (buf.items.len == 0) {
                    try out.writeAll("\r\n");
                    try out.flush();
                    return .eof;
                }
                break;
            };

            // Reset consecutive Ctrl-C counter on any other key.
            if (b != 0x03) ed.consecutive_ctrl_c = 0;

            switch (b) {
                '\r', '\n' => {
                    try out.writeAll("\r\n");
                    try out.flush();
                    try ed.last_line.appendSlice(ed.gpa, buf.items);
                    return .{ .line = ed.last_line.items };
                },
                0x03 => { // Ctrl-C
                    if (buf.items.len == 0) {
                        ed.consecutive_ctrl_c += 1;
                        if (ed.consecutive_ctrl_c >= 2) {
                            try out.writeAll("\r\n");
                            try out.flush();
                            return .eof;
                        }
                        try out.writeAll("\r\n(To exit, press Ctrl+C again or Ctrl+D or type .exit)\r\n");
                        try ed.refreshLine(prompt, buf.items, cursor, out);
                    } else {
                        buf.clearRetainingCapacity();
                        cursor = 0;
                        try out.writeAll("^C\r\n");
                        try out.flush();
                        return .interrupt;
                    }
                },
                0x04 => { // Ctrl-D
                    if (buf.items.len == 0) {
                        try out.writeAll("\r\n");
                        try out.flush();
                        return .eof;
                    }
                    if (cursor < buf.items.len) {
                        const next_cp = nextCharBoundary(buf.items, cursor);
                        deleteRange(&buf, cursor, next_cp);
                        try ed.refreshLine(prompt, buf.items, cursor, out);
                    }
                },
                0x01 => { // Ctrl-A (Home)
                    cursor = 0;
                    try ed.refreshLine(prompt, buf.items, cursor, out);
                },
                0x05 => { // Ctrl-E (End)
                    cursor = buf.items.len;
                    try ed.refreshLine(prompt, buf.items, cursor, out);
                },
                0x02 => { // Ctrl-B (Left)
                    cursor = prevCharBoundary(buf.items, cursor);
                    try ed.refreshLine(prompt, buf.items, cursor, out);
                },
                0x06 => { // Ctrl-F (Right)
                    cursor = nextCharBoundary(buf.items, cursor);
                    try ed.refreshLine(prompt, buf.items, cursor, out);
                },
                0x0b => { // Ctrl-K (kill to end)
                    buf.shrinkRetainingCapacity(cursor);
                    try ed.refreshLine(prompt, buf.items, cursor, out);
                },
                0x15 => { // Ctrl-U (kill to start)
                    if (cursor > 0) {
                        deleteRange(&buf, 0, cursor);
                        cursor = 0;
                        try ed.refreshLine(prompt, buf.items, cursor, out);
                    }
                },
                0x17 => { // Ctrl-W (kill previous word)
                    if (cursor > 0) {
                        const word_start = prevWordBoundary(buf.items, cursor);
                        deleteRange(&buf, word_start, cursor);
                        cursor = word_start;
                        try ed.refreshLine(prompt, buf.items, cursor, out);
                    }
                },
                0x0c => { // Ctrl-L (clear screen)
                    try out.writeAll("\x1b[H\x1b[2J");
                    try ed.refreshLine(prompt, buf.items, cursor, out);
                },
                0x12 => { // Ctrl-R (reverse incremental search)
                    const accepted = try ed.reverseSearch(prompt, &buf, &cursor, reader, out);
                    if (accepted == .eof) return .eof;
                    try ed.refreshLine(prompt, buf.items, cursor, out);
                },
                0x09 => { // Tab
                    if (ed.config.complete_fn) |cfn| {
                        var res = try cfn(ed.config.complete_ctx.?, buf.items, cursor, ed.gpa);
                        defer res.deinit(ed.gpa);
                        if (res.matches.len == 1) {
                            const match = res.matches[0];
                            try replaceRange(ed.gpa, &buf, res.replace_start, cursor, match);
                            cursor = res.replace_start + match.len;
                            try ed.refreshLine(prompt, buf.items, cursor, out);
                        } else if (res.matches.len > 1) {
                            const lcp = complete.longestCommonPrefix(res.matches);
                            const current_len = cursor - res.replace_start;
                            if (lcp.len > current_len) {
                                try replaceRange(ed.gpa, &buf, res.replace_start, cursor, lcp);
                                cursor = res.replace_start + lcp.len;
                                try ed.refreshLine(prompt, buf.items, cursor, out);
                            } else {
                                try out.writeAll("\r\n");
                                try printColumns(res.matches, out);
                                try ed.refreshLine(prompt, buf.items, cursor, out);
                            }
                        }
                    }
                },
                0x7f, 0x08 => { // Backspace
                    if (cursor > 0) {
                        const prev = prevCharBoundary(buf.items, cursor);
                        deleteRange(&buf, prev, cursor);
                        cursor = prev;
                        try ed.refreshLine(prompt, buf.items, cursor, out);
                    }
                },
                0x1b => { // Escape sequence
                    const seq1 = try reader.read_byte(reader.ctx) orelse continue;
                    if (seq1 == '[') {
                        const seq2 = try reader.read_byte(reader.ctx) orelse continue;
                        switch (seq2) {
                            'A' => { // Up
                                if (ed.history.items.len > 0 and hist_idx > 0) {
                                    if (!browsing_history) {
                                        draft.clearRetainingCapacity();
                                        try draft.appendSlice(ed.gpa, buf.items);
                                        browsing_history = true;
                                    }
                                    hist_idx -= 1;
                                    buf.clearRetainingCapacity();
                                    try buf.appendSlice(ed.gpa, ed.history.items[hist_idx]);
                                    cursor = buf.items.len;
                                    try ed.refreshLine(prompt, buf.items, cursor, out);
                                }
                            },
                            'B' => { // Down
                                if (browsing_history) {
                                    if (hist_idx + 1 < ed.history.items.len) {
                                        hist_idx += 1;
                                        buf.clearRetainingCapacity();
                                        try buf.appendSlice(ed.gpa, ed.history.items[hist_idx]);
                                    } else {
                                        hist_idx = ed.history.items.len;
                                        browsing_history = false;
                                        buf.clearRetainingCapacity();
                                        try buf.appendSlice(ed.gpa, draft.items);
                                    }
                                    cursor = buf.items.len;
                                    try ed.refreshLine(prompt, buf.items, cursor, out);
                                }
                            },
                            'C' => { // Right
                                cursor = nextCharBoundary(buf.items, cursor);
                                try ed.refreshLine(prompt, buf.items, cursor, out);
                            },
                            'D' => { // Left
                                cursor = prevCharBoundary(buf.items, cursor);
                                try ed.refreshLine(prompt, buf.items, cursor, out);
                            },
                            'H' => { // Home
                                cursor = 0;
                                try ed.refreshLine(prompt, buf.items, cursor, out);
                            },
                            'F' => { // End
                                cursor = buf.items.len;
                                try ed.refreshLine(prompt, buf.items, cursor, out);
                            },
                            '1' => {
                                const seq3 = try reader.read_byte(reader.ctx) orelse continue;
                                if (seq3 == '~') {
                                    cursor = 0;
                                    try ed.refreshLine(prompt, buf.items, cursor, out);
                                } else if (seq3 == ';') {
                                    const mod = try reader.read_byte(reader.ctx) orelse continue;
                                    const dir = try reader.read_byte(reader.ctx) orelse continue;
                                    if (mod == '5' and dir == 'D') {
                                        cursor = prevWordBoundary(buf.items, cursor);
                                        try ed.refreshLine(prompt, buf.items, cursor, out);
                                    } else if (mod == '5' and dir == 'C') {
                                        cursor = nextWordBoundary(buf.items, cursor);
                                        try ed.refreshLine(prompt, buf.items, cursor, out);
                                    }
                                }
                            },
                            '3' => {
                                const seq3 = try reader.read_byte(reader.ctx) orelse continue;
                                if (seq3 == '~' and cursor < buf.items.len) {
                                    const next_cp = nextCharBoundary(buf.items, cursor);
                                    deleteRange(&buf, cursor, next_cp);
                                    try ed.refreshLine(prompt, buf.items, cursor, out);
                                }
                            },
                            '4' => {
                                const seq3 = try reader.read_byte(reader.ctx) orelse continue;
                                if (seq3 == '~') {
                                    cursor = buf.items.len;
                                    try ed.refreshLine(prompt, buf.items, cursor, out);
                                }
                            },
                            else => {},
                        }
                    } else if (seq1 == 'b' or seq1 == 'B') { // Alt-B
                        cursor = prevWordBoundary(buf.items, cursor);
                        try ed.refreshLine(prompt, buf.items, cursor, out);
                    } else if (seq1 == 'f' or seq1 == 'F') { // Alt-F
                        cursor = nextWordBoundary(buf.items, cursor);
                        try ed.refreshLine(prompt, buf.items, cursor, out);
                    }
                },
                else => {
                    if (b >= 0x20) {
                        const seq_len = std.unicode.utf8ByteSequenceLength(b) catch 1;
                        var cp_bytes: [4]u8 = undefined;
                        cp_bytes[0] = b;
                        var valid_len: usize = 1;
                        while (valid_len < seq_len) : (valid_len += 1) {
                            cp_bytes[valid_len] = (try reader.read_byte(reader.ctx)) orelse break;
                        }
                        try insertSlice(ed.gpa, &buf, cursor, cp_bytes[0..valid_len]);
                        cursor += valid_len;
                        try ed.refreshLine(prompt, buf.items, cursor, out);
                    }
                },
            }
        }

        try ed.last_line.appendSlice(ed.gpa, buf.items);
        return .{ .line = ed.last_line.items };
    }

    const SearchOutcome = enum { done, eof };

    fn reverseSearch(
        ed: *LineEditor,
        prompt: []const u8,
        buf: *std.ArrayList(u8),
        cursor: *usize,
        reader: ByteReader,
        out: *Writer,
    ) !SearchOutcome {
        _ = prompt;
        var query: std.ArrayList(u8) = .empty;
        defer query.deinit(ed.gpa);
        var match_idx: ?usize = if (ed.history.items.len > 0) ed.history.items.len - 1 else null;

        while (true) {
            const matched: []const u8 = if (match_idx) |idx| ed.history.items[idx] else "";
            try out.print("\r\x1b[K(reverse-i-search)'{s}': {s}", .{ query.items, matched });
            try out.flush();

            const b = (try reader.read_byte(reader.ctx)) orelse return .eof;
            switch (b) {
                '\r', '\n' => {
                    if (match_idx) |idx| {
                        buf.clearRetainingCapacity();
                        try buf.appendSlice(ed.gpa, ed.history.items[idx]);
                        cursor.* = buf.items.len;
                    }
                    return .done;
                },
                0x1b, 0x07, 0x03 => { // Esc, Ctrl-G, Ctrl-C cancels search
                    return .done;
                },
                0x12 => { // Ctrl-R again: older match
                    if (match_idx) |cur| {
                        if (cur > 0) {
                            match_idx = findMatchBackward(ed.history.items, cur - 1, query.items) orelse match_idx;
                        }
                    }
                },
                0x7f, 0x08 => { // Backspace
                    if (query.items.len > 0) {
                        const prev = prevCharBoundary(query.items, query.items.len);
                        query.shrinkRetainingCapacity(prev);
                        if (ed.history.items.len > 0) {
                            match_idx = findMatchBackward(ed.history.items, ed.history.items.len - 1, query.items);
                        }
                    }
                },
                else => {
                    if (b >= 0x20) {
                        try query.append(ed.gpa, b);
                        if (ed.history.items.len > 0) {
                            const start = match_idx orelse ed.history.items.len - 1;
                            match_idx = findMatchBackward(ed.history.items, start, query.items);
                        }
                    }
                },
            }
        }
    }

    fn findMatchBackward(items: []const []const u8, start_idx: usize, query: []const u8) ?usize {
        if (items.len == 0) return null;
        var i: usize = @min(start_idx, items.len - 1);
        while (true) {
            if (query.len == 0 or std.mem.indexOf(u8, items[i], query) != null) {
                return i;
            }
            if (i == 0) break;
            i -= 1;
        }
        return null;
    }

    fn refreshLine(ed: *const LineEditor, prompt: []const u8, line: []const u8, cursor: usize, out: *Writer) Writer.Error!void {
        try out.writeAll("\r\x1b[K");
        try out.writeAll(prompt);
        if (ed.config.color) {
            if (ed.config.highlight_fn) |hfn| {
                try hfn(line, out);
            } else {
                try out.writeAll(line);
            }
        } else {
            try out.writeAll(line);
        }
        const total_cols = utf8DisplayCount(prompt) + utf8DisplayCount(line[0..@min(cursor, line.len)]);
        try out.print("\r\x1b[{d}C", .{total_cols});
        try out.flush();
    }
};

fn printColumns(matches: []const []const u8, out: *Writer) Writer.Error!void {
    var max_len: usize = 0;
    for (matches) |m| max_len = @max(max_len, m.len);
    const col_width = max_len + 2;
    const term_width: usize = 80;
    const cols = @max(@as(usize, 1), term_width / col_width);
    for (matches, 0..) |m, i| {
        try out.writeAll(m);
        if ((i + 1) % cols == 0 or i + 1 == matches.len) {
            try out.writeAll("\r\n");
        } else {
            try out.splatByteAll(' ', col_width - m.len);
        }
    }
}

const FdReader = struct {
    fd: posix.fd_t,

    fn readByteFn(ctx: *anyopaque) anyerror!?u8 {
        const self: *FdReader = @ptrCast(@alignCast(ctx));
        var byte: [1]u8 = undefined;
        const n = try posix.read(self.fd, &byte);
        if (n == 0) return null;
        return byte[0];
    }

    fn interface(self: *FdReader) ByteReader {
        return .{ .ctx = self, .read_byte = readByteFn };
    }
};

fn prevCharBoundary(buf: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = pos - 1;
    while (i > 0 and (buf[i] & 0xC0) == 0x80) : (i -= 1) {}
    return i;
}

fn nextCharBoundary(buf: []const u8, pos: usize) usize {
    if (pos >= buf.len) return buf.len;
    const len = std.unicode.utf8ByteSequenceLength(buf[pos]) catch 1;
    return @min(pos + len, buf.len);
}

fn prevWordBoundary(buf: []const u8, pos: usize) usize {
    var i = pos;
    while (i > 0 and buf[i - 1] == ' ') : (i -= 1) {}
    while (i > 0 and buf[i - 1] != ' ') : (i -= 1) {}
    return i;
}

fn nextWordBoundary(buf: []const u8, pos: usize) usize {
    var i = pos;
    while (i < buf.len and buf[i] == ' ') : (i += 1) {}
    while (i < buf.len and buf[i] != ' ') : (i += 1) {}
    return i;
}

fn utf8DisplayCount(s: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += @min(len, s.len - i);
        count += 1;
    }
    return count;
}

fn deleteRange(buf: *std.ArrayList(u8), start: usize, end: usize) void {
    if (end <= start) return;
    const tail = buf.items[end..];
    std.mem.copyForwards(u8, buf.items[start .. start + tail.len], tail);
    buf.shrinkRetainingCapacity(buf.items.len - (end - start));
}

fn insertSlice(gpa: Allocator, buf: *std.ArrayList(u8), pos: usize, slice: []const u8) Allocator.Error!void {
    try buf.ensureUnusedCapacity(gpa, slice.len);
    const old_len = buf.items.len;
    buf.items.len += slice.len;
    std.mem.copyBackwards(u8, buf.items[pos + slice.len .. old_len + slice.len], buf.items[pos..old_len]);
    @memcpy(buf.items[pos .. pos + slice.len], slice);
}

fn replaceRange(gpa: Allocator, buf: *std.ArrayList(u8), start: usize, end: usize, replacement: []const u8) Allocator.Error!void {
    deleteRange(buf, start, end);
    try insertSlice(gpa, buf, start, replacement);
}
