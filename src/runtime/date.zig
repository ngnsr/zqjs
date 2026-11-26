//! ECMAScript Date calendar math, POSIX local timezone, parsing, and formatting (M50, D80).
//!
//! All calendar conversions share one `decompose` / `daysFromCivil` / `civilFromDays` engine
//! (Howard Hinnant's civil-date algorithm) over the full ECMAScript ±8.64e15 ms range.

const std = @import("std");
const builtin = @import("builtin");

pub const ms_per_second: f64 = 1_000.0;
pub const ms_per_minute: f64 = 60_000.0;
pub const ms_per_hour: f64 = 3_600_000.0;
pub const ms_per_day: f64 = 86_400_000.0;
pub const ms_per_day_i64: i64 = 86_400_000;
pub const max_time_ms: f64 = 8.64e15;

pub const Decomposed = struct {
    year: i64,
    /// 0-based month (0 = January .. 11 = December), matching JS Date.
    month: u8,
    /// 1-based day of month (1 .. 31).
    day: u8,
    /// Day of week (0 = Sunday .. 6 = Saturday).
    weekday: u8,
    hour: u8,
    minute: u8,
    second: u8,
    ms: u16,
};

pub const LocalZone = struct {
    offset_sec: i64,
    abbr: [16]u8 = undefined,
    abbr_len: usize = 0,
};

const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

/// Current system UTC epoch time in milliseconds.
pub fn systemNowMs() f64 {
    if (comptime builtin.link_libc) {
        var tv: std.c.timeval = undefined;
        _ = std.c.gettimeofday(&tv, null);
        const sec_ms = @as(f64, @floatFromInt(tv.sec)) * ms_per_second;
        const usec_ms = @as(f64, @floatFromInt(@divTrunc(tv.usec, 1000)));
        return timeClip(sec_ms + usec_ms);
    } else if (comptime builtin.os.tag == .linux) {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
        const sec_ms = @as(f64, @floatFromInt(ts.sec)) * ms_per_second;
        const nsec_ms = @as(f64, @floatFromInt(@divTrunc(ts.nsec, 1_000_000)));
        return timeClip(sec_ms + nsec_ms);
    } else {
        return 0.0;
    }
}

/// ES `TimeClip(time)`: truncates toward zero, normalizes `-0` to `+0`, and returns `NaN`
/// if `time` is non-finite or `|time| > 8.64e15`.
pub fn timeClip(time: f64) f64 {
    if (!std.math.isFinite(time) or @abs(time) > max_time_ms) {
        return std.math.nan(f64);
    }
    const clipped = @trunc(time);
    return if (clipped == 0.0) 0.0 else clipped;
}

/// ES `ToIntegerOrInfinity` for finite-required Date arguments: returns `null` on NaN/±Infinity.
fn truncFinite(x: f64) ?f64 {
    if (!std.math.isFinite(x)) return null;
    const t = @trunc(x);
    return if (t == 0.0) 0.0 else t;
}

/// Howard Hinnant's civil-from-days: `z_in` is days since 1970-01-01.
/// Returns `year` (astronomical, 0 = 1 BCE), `month` (1..12), `day` (1..31).
pub fn civilFromDays(z_in: i64) struct { year: i64, month: u8, day: u8 } {
    const z: i64 = z_in + 719468;
    const era: i64 = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097; // [0, 146096]
    const yoe: i64 = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365); // [0, 399]
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100)); // [0, 365]
    const mp: i64 = @divTrunc(5 * doy + 2, 153); // [0, 11]
    const d: u8 = @intCast(doy - @divTrunc(153 * mp + 2, 5) + 1); // [1, 31]
    const m: u8 = @intCast(mp + (if (mp < 10) @as(i64, 3) else -9)); // [1, 12]
    return .{
        .year = y + @intFromBool(m <= 2),
        .month = m,
        .day = d,
    };
}

/// Howard Hinnant's days-from-civil: `m` is 1..12, `d` is 1..31.
/// Returns days since 1970-01-01.
pub fn daysFromCivil(y: i64, m: i64, d: i64) i64 {
    const y_adj: i64 = y - @intFromBool(m <= 2);
    const era: i64 = @divFloor(y_adj, 400);
    const yoe: i64 = y_adj - era * 400; // [0, 399]
    const m_adj: i64 = m + (if (m > 2) @as(i64, -3) else 9); // [0, 11]
    const doy: i64 = @divTrunc(153 * m_adj + 2, 5) + d - 1; // [0, 365]
    const doe: i64 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// ES `WeekDay(t)`: 0 = Sunday .. 6 = Saturday.
pub fn weekDay(t: f64) f64 {
    if (!std.math.isFinite(t)) return std.math.nan(f64);
    const day_num = @divFloor(@as(i64, @intFromFloat(@trunc(t))), ms_per_day_i64);
    return @floatFromInt(@mod(day_num + 4, 7));
}

/// Decomposes a finite timestamp `ms` into calendar fields. Returns `null` for non-finite `ms`.
pub fn decompose(ms_in: f64) ?Decomposed {
    if (!std.math.isFinite(ms_in)) return null;
    // Clamp slightly outside ±8.64e15 if local offset pushed it past, as long as it fits i64.
    const trunc_ms = @trunc(ms_in);
    if (@abs(trunc_ms) > 9.0e15) return null;
    const t: i64 = @intFromFloat(trunc_ms);
    const day_num: i64 = @divFloor(t, ms_per_day_i64);
    const tod: i64 = @mod(t, ms_per_day_i64);
    const civil = civilFromDays(day_num);
    return .{
        .year = civil.year,
        .month = civil.month - 1,
        .day = civil.day,
        .weekday = @intCast(@mod(day_num + 4, 7)),
        .hour = @intCast(@divTrunc(tod, 3_600_000)),
        .minute = @intCast(@divTrunc(@mod(tod, 3_600_000), 60_000)),
        .second = @intCast(@divTrunc(@mod(tod, 60_000), 1_000)),
        .ms = @intCast(@mod(tod, 1_000)),
    };
}

/// ES `MakeTime(hour, min, sec, ms)`.
pub fn makeTime(hour: f64, min: f64, sec: f64, ms: f64) f64 {
    const h = truncFinite(hour) orelse return std.math.nan(f64);
    const m = truncFinite(min) orelse return std.math.nan(f64);
    const s = truncFinite(sec) orelse return std.math.nan(f64);
    const milli = truncFinite(ms) orelse return std.math.nan(f64);
    return h * ms_per_hour + m * ms_per_minute + s * ms_per_second + milli;
}

/// ES `MakeDay(year, month, date)`.
pub fn makeDay(year: f64, month: f64, date: f64) f64 {
    const y = truncFinite(year) orelse return std.math.nan(f64);
    const m = truncFinite(month) orelse return std.math.nan(f64);
    const dt = truncFinite(date) orelse return std.math.nan(f64);
    const ym = y + @floor(m / 12.0);
    if (!std.math.isFinite(ym) or @abs(ym) > 1.0e8) return std.math.nan(f64);
    const mn = @mod(m, 12.0);
    const days = daysFromCivil(@intFromFloat(ym), @as(i64, @intFromFloat(mn)) + 1, 1);
    return @as(f64, @floatFromInt(days)) + dt - 1.0;
}

/// ES `MakeDate(day, time)`.
pub fn makeDate(day: f64, time: f64) f64 {
    if (!std.math.isFinite(day) or !std.math.isFinite(time)) return std.math.nan(f64);
    const tv = day * ms_per_day + time;
    return if (!std.math.isFinite(tv)) std.math.nan(f64) else tv;
}

/// Queries POSIX `localtime_r` for the local timezone offset (seconds east of UTC) and
/// zone abbreviation at UTC timestamp `t_utc` (in ms). Falls back to UTC when built
/// without libc (preserving libc-free Linux builds per D45).
pub fn localZoneAt(t_utc: f64) LocalZone {
    if (!std.math.isFinite(t_utc)) return .{ .offset_sec = 0 };
    if (comptime !(builtin.link_libc and builtin.os.tag != .windows)) {
        return .{ .offset_sec = 0 };
    }
    const c = struct {
        extern "c" fn localtime_r(noalias timer: *const std.c.time_t, noalias result: *Tm) ?*Tm;
    };
    const sec_f = @divFloor(t_utc, ms_per_second);
    if (@abs(sec_f) <= 9.0e12) {
        const sec_i64: i64 = @intFromFloat(sec_f);
        if (std.math.cast(std.c.time_t, sec_i64)) |sec_c| {
            var tm: Tm = undefined;
            if (c.localtime_r(&sec_c, &tm) != null) {
                return extractZone(&tm);
            }
        }
    }
    // Fallback for platforms where `time_t` is 32-bit or `localtime_r` rejects extreme years:
    // map to an equivalent year in 1970..2037 with matching leap-year and Jan 1 weekday.
    const equiv_sec = equivalentPosixSec(t_utc);
    if (std.math.cast(std.c.time_t, equiv_sec)) |sec_c| {
        var tm: Tm = undefined;
        if (c.localtime_r(&sec_c, &tm) != null) {
            return extractZone(&tm);
        }
    }
    return .{ .offset_sec = 0 };
}

fn extractZone(tm: *const Tm) LocalZone {
    var z: LocalZone = .{ .offset_sec = @intCast(tm.tm_gmtoff) };
    if (tm.tm_zone) |ptr| {
        const slice = std.mem.span(ptr);
        const n = @min(slice.len, z.abbr.len);
        @memcpy(z.abbr[0..n], slice[0..n]);
        z.abbr_len = n;
    }
    return z;
}

fn isLeapYear(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

fn equivalentPosixSec(t_utc: f64) i64 {
    const t: i64 = @intFromFloat(@trunc(t_utc));
    const day_num = @divFloor(t, ms_per_day_i64);
    const tod = @mod(t, ms_per_day_i64);
    const civil = civilFromDays(day_num);
    const leap = isLeapYear(civil.year);
    const jan1_wd = @mod(daysFromCivil(civil.year, 1, 1) + 4, 7);
    var cand: i64 = 1972;
    while (cand <= 2035) : (cand += 1) {
        if (isLeapYear(cand) == leap and @mod(daysFromCivil(cand, 1, 1) + 4, 7) == jan1_wd) {
            const d = daysFromCivil(cand, civil.month, civil.day);
            return d * 86400 + @divTrunc(tod, 1000);
        }
    }
    return 0;
}

/// ES `LocalTime(t)`: UTC ms -> local ms.
pub fn localTime(t_utc: f64) f64 {
    if (!std.math.isFinite(t_utc)) return std.math.nan(f64);
    const z = localZoneAt(t_utc);
    return t_utc + @as(f64, @floatFromInt(z.offset_sec)) * ms_per_second;
}

/// ES `UTC(t)`: local ms -> UTC ms (two-step fixed-point for DST boundaries).
pub fn utcFromLocal(t_local: f64) f64 {
    if (!std.math.isFinite(t_local)) return std.math.nan(f64);
    const z1 = localZoneAt(t_local);
    const guess = t_local - @as(f64, @floatFromInt(z1.offset_sec)) * ms_per_second;
    const z2 = localZoneAt(guess);
    return t_local - @as(f64, @floatFromInt(z2.offset_sec)) * ms_per_second;
}

/// Converts a POSIX UTC offset in seconds (east of UTC) into ECMAScript
/// `getTimezoneOffset()` minutes (`(t - LocalTime(t)) / msPerMinute`),
/// preserving sub-minute historical LMT offsets and normalizing `-0` to `+0`.
fn offsetMinutesFromSeconds(offset_sec: i64) f64 {
    if (offset_sec == 0) return 0.0;
    return -@as(f64, @floatFromInt(offset_sec)) / 60.0;
}

/// ES `Date.prototype.getTimezoneOffset()` in minutes (UTC - local, so UTC+03:00 returns -180).
pub fn timezoneOffsetMinutes(t_utc: f64) f64 {
    if (!std.math.isFinite(t_utc)) return std.math.nan(f64);
    const z = localZoneAt(t_utc);
    return offsetMinutesFromSeconds(z.offset_sec);
}

// ---------------------------------------------------------------- Formatting

const day_names = [7][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [12][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// Formats a finite `t_utc` as ISO-8601 (`YYYY-MM-DDTHH:mm:ss.sssZ` or `±YYYYYY-...`).
/// Caller must ensure `t_utc` is finite (throws RangeError at JS layer for NaN).
pub fn formatISO(buf: *[64]u8, t_utc: f64) []const u8 {
    const d = decompose(t_utc) orelse unreachable;
    var w: std.Io.Writer = .fixed(buf);
    writeIsoYear(&w, d.year) catch unreachable;
    w.print("-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        d.month + 1, d.day, d.hour, d.minute, d.second, d.ms,
    }) catch unreachable;
    return w.buffered();
}

fn writeIsoYear(w: *std.Io.Writer, year: i64) std.Io.Writer.Error!void {
    if (year < 0) {
        const abs_y: u64 = @intCast(-year);
        try w.print("-{d:0>6}", .{abs_y});
    } else if (year > 9999) {
        const abs_y: u64 = @intCast(year);
        try w.print("+{d:0>6}", .{abs_y});
    } else {
        const abs_y: u64 = @intCast(year);
        try w.print("{d:0>4}", .{abs_y});
    }
}

fn writeFullYearText(w: *std.Io.Writer, year: i64) std.Io.Writer.Error!void {
    if (year < 0) {
        const abs_y: u64 = @intCast(-year);
        try w.print("-{d:0>4}", .{abs_y});
    } else {
        const abs_y: u64 = @intCast(year);
        try w.print("{d:0>4}", .{abs_y});
    }
}

/// Formats `t_utc` in RFC-2822 / `Date.prototype.toUTCString()` format:
/// `"Thu, 01 Jan 1970 00:00:00 GMT"` (or `"Invalid Date"` on NaN).
pub fn formatUTC(buf: *[64]u8, t_utc: f64) []const u8 {
    const d = decompose(t_utc) orelse return "Invalid Date";
    var w: std.Io.Writer = .fixed(buf);
    w.print("{s}, {d:0>2} {s} ", .{
        day_names[d.weekday], d.day, month_names[d.month],
    }) catch unreachable;
    writeFullYearText(&w, d.year) catch unreachable;
    w.print(" {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        d.hour, d.minute, d.second,
    }) catch unreachable;
    return w.buffered();
}

/// Formats `t_utc` in local `Date.prototype.toDateString()` format: `"Thu Jan 01 1970"`.
pub fn formatDateString(buf: *[64]u8, t_utc: f64) []const u8 {
    const d = decompose(localTime(t_utc)) orelse return "Invalid Date";
    var w: std.Io.Writer = .fixed(buf);
    w.print("{s} {s} {d:0>2} ", .{
        day_names[d.weekday], month_names[d.month], d.day,
    }) catch unreachable;
    writeFullYearText(&w, d.year) catch unreachable;
    return w.buffered();
}

/// Formats `t_utc` in local `Date.prototype.toTimeString()` format: `"03:00:00 GMT+0300 (EET)"`.
pub fn formatTimeString(buf: *[96]u8, t_utc: f64) []const u8 {
    if (!std.math.isFinite(t_utc)) return "Invalid Date";
    const zone = localZoneAt(t_utc);
    const local_ms = t_utc + @as(f64, @floatFromInt(zone.offset_sec)) * ms_per_second;
    const d = decompose(local_ms) orelse return "Invalid Date";
    var w: std.Io.Writer = .fixed(buf);
    writeTimeAndZone(&w, d, zone) catch unreachable;
    return w.buffered();
}

/// Formats `t_utc` in local `Date.prototype.toString()` format:
/// `"Thu Jan 01 1970 03:00:00 GMT+0300 (EET)"`.
pub fn formatToString(buf: *[128]u8, t_utc: f64) []const u8 {
    if (!std.math.isFinite(t_utc)) return "Invalid Date";
    const zone = localZoneAt(t_utc);
    const local_ms = t_utc + @as(f64, @floatFromInt(zone.offset_sec)) * ms_per_second;
    const d = decompose(local_ms) orelse return "Invalid Date";
    var w: std.Io.Writer = .fixed(buf);
    w.print("{s} {s} {d:0>2} ", .{
        day_names[d.weekday], month_names[d.month], d.day,
    }) catch unreachable;
    writeFullYearText(&w, d.year) catch unreachable;
    w.writeByte(' ') catch unreachable;
    writeTimeAndZone(&w, d, zone) catch unreachable;
    return w.buffered();
}

fn writeTimeAndZone(w: *std.Io.Writer, d: Decomposed, zone: LocalZone) std.Io.Writer.Error!void {
    const sign: u8 = if (zone.offset_sec < 0) '-' else '+';
    const abs_sec: u64 = @intCast(if (zone.offset_sec < 0) -zone.offset_sec else zone.offset_sec);
    const total_min = abs_sec / 60;
    const tz_h = total_min / 60;
    const tz_m = total_min % 60;
    try w.print("{d:0>2}:{d:0>2}:{d:0>2} GMT{c}{d:0>2}{d:0>2}", .{
        d.hour, d.minute, d.second, sign, tz_h, tz_m,
    });
    if (zone.abbr_len > 0) {
        try w.print(" ({s})", .{zone.abbr[0..zone.abbr_len]});
    }
}

// ---------------------------------------------------------------- Parsing

/// Parses an ECMAScript date string (ISO-8601, RFC-2822 / `toUTCString`, or `toString`).
/// Returns `NaN` if the string cannot be parsed.
pub fn parse(raw: []const u8) f64 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return std.math.nan(f64);
    if (parseIso(s)) |t| return timeClip(t);
    if (parseRfcOrToString(s)) |t| return timeClip(t);
    return std.math.nan(f64);
}

fn parseDigits(s: []const u8, pos: *usize, count: usize) ?i64 {
    if (pos.* + count > s.len) return null;
    var val: i64 = 0;
    for (s[pos.* .. pos.* + count]) |ch| {
        if (ch < '0' or ch > '9') return null;
        val = val * 10 + (ch - '0');
    }
    pos.* += count;
    return val;
}

fn parseIso(s: []const u8) ?f64 {
    var pos: usize = 0;
    var year: i64 = 0;
    if (s[0] == '+' or s[0] == '-') {
        const neg = s[0] == '-';
        pos = 1;
        const y = parseDigits(s, &pos, 6) orelse return null;
        if (neg and y == 0) return null; // ES2024: -000000 is invalid
        year = if (neg) -y else y;
    } else {
        year = parseDigits(s, &pos, 4) orelse return null;
    }

    var month: i64 = 1;
    var day: i64 = 1;
    if (pos < s.len and s[pos] == '-') {
        pos += 1;
        month = parseDigits(s, &pos, 2) orelse return null;
        if (month < 1 or month > 12) return null;
        if (pos < s.len and s[pos] == '-') {
            pos += 1;
            day = parseDigits(s, &pos, 2) orelse return null;
            if (day < 1 or day > 31) return null;
        }
    }

    var has_time = false;
    var hour: i64 = 0;
    var minute: i64 = 0;
    var second: i64 = 0;
    var ms: i64 = 0;
    var tz_offset_ms: ?f64 = null;

    if (pos < s.len) {
        if (s[pos] != 'T') return null;
        has_time = true;
        pos += 1;
        hour = parseDigits(s, &pos, 2) orelse return null;
        if (pos >= s.len or s[pos] != ':') return null;
        pos += 1;
        minute = parseDigits(s, &pos, 2) orelse return null;
        if (minute > 59) return null;
        if (pos < s.len and s[pos] == ':') {
            pos += 1;
            second = parseDigits(s, &pos, 2) orelse return null;
            if (second > 59) return null;
            if (pos < s.len and s[pos] == '.') {
                pos += 1;
                const frac_start = pos;
                var digits: usize = 0;
                var scale: i64 = 100;
                while (pos < s.len and s[pos] >= '0' and s[pos] <= '9') : (pos += 1) {
                    if (digits < 3) {
                        ms += (s[pos] - '0') * scale;
                        scale = @divTrunc(scale, 10);
                    }
                    digits += 1;
                }
                if (pos == frac_start) return null;
            }
        }
        if (hour > 24 or (hour == 24 and (minute != 0 or second != 0 or ms != 0))) return null;

        if (pos < s.len) {
            if (s[pos] == 'Z') {
                pos += 1;
                tz_offset_ms = 0.0;
            } else if (s[pos] == '+' or s[pos] == '-') {
                const tz_neg = s[pos] == '-';
                pos += 1;
                const tz_h = parseDigits(s, &pos, 2) orelse return null;
                if (tz_h > 23) return null;
                if (pos < s.len and s[pos] == ':') pos += 1;
                const tz_m = parseDigits(s, &pos, 2) orelse return null;
                if (tz_m > 59) return null;
                const total_ms = @as(f64, @floatFromInt(tz_h * 60 + tz_m)) * ms_per_minute;
                tz_offset_ms = if (tz_neg) -total_ms else total_ms;
            } else {
                return null;
            }
        }
    }

    if (pos != s.len) return null;

    const d = makeDay(@floatFromInt(year), @floatFromInt(month - 1), @floatFromInt(day));
    const t = makeTime(@floatFromInt(hour), @floatFromInt(minute), @floatFromInt(second), @floatFromInt(ms));
    const dt = makeDate(d, t);
    if (!std.math.isFinite(dt)) return null;

    if (!has_time) return dt; // Date-only ISO strings are UTC per ES spec.
    if (tz_offset_ms) |off| return dt - off;
    return utcFromLocal(dt); // Time without Z/offset is local time per ES spec.
}

fn parseMonthName(tok: []const u8) ?i64 {
    if (tok.len < 3) return null;
    for (month_names, 0..) |m, idx| {
        if (std.ascii.eqlIgnoreCase(tok[0..3], m)) return @intCast(idx);
    }
    return null;
}

fn parseRfcOrToString(s: []const u8) ?f64 {
    // Handles:
    //   "Thu, 01 Jan 1970 00:00:00 GMT"
    //   "Thu Jan 01 1970 03:00:00 GMT+0300 (EET)"
    //   "01 Jan 1970 00:00:00 GMT"
    var rest = s;
    // Strip optional "(...)" timezone comment at the end.
    if (std.mem.lastIndexOfScalar(u8, rest, '(')) |paren| {
        if (rest[rest.len - 1] == ')') {
            rest = std.mem.trimEnd(u8, rest[0..paren], " \t");
        }
    }

    var it = std.mem.tokenizeAny(u8, rest, " \t,");
    const first = it.next() orelse return null;

    // Optional weekday prefix (3+ alpha letters, e.g. "Thu" or "Thursday")
    var tok = first;
    if (first.len >= 3 and std.ascii.isAlphabetic(first[0]) and parseMonthName(first) == null) {
        tok = it.next() orelse return null;
    }

    var day: i64 = undefined;
    var month: i64 = undefined;
    if (parseMonthName(tok)) |m| {
        // `toString()` / `toDateString()` order: Month Day Year
        month = m;
        const day_tok = it.next() orelse return null;
        day = std.fmt.parseInt(i64, day_tok, 10) catch return null;
    } else {
        // RFC-2822 order: Day Month Year
        day = std.fmt.parseInt(i64, tok, 10) catch return null;
        const mon_tok = it.next() orelse return null;
        month = parseMonthName(mon_tok) orelse return null;
    }
    if (day < 1 or day > 31) return null;

    const year_tok = it.next() orelse return null;
    const year = std.fmt.parseInt(i64, year_tok, 10) catch return null;

    var hour: i64 = 0;
    var minute: i64 = 0;
    var second: i64 = 0;
    var tz_offset_ms: ?f64 = null;

    if (it.next()) |time_tok| {
        var tpos: usize = 0;
        hour = parseDigits(time_tok, &tpos, 2) orelse return null;
        if (tpos >= time_tok.len or time_tok[tpos] != ':') return null;
        tpos += 1;
        minute = parseDigits(time_tok, &tpos, 2) orelse return null;
        if (tpos < time_tok.len) {
            if (time_tok[tpos] != ':') return null;
            tpos += 1;
            second = parseDigits(time_tok, &tpos, 2) orelse return null;
        }
        if (tpos != time_tok.len or hour > 23 or minute > 59 or second > 59) return null;

        if (it.next()) |tz_tok| {
            if (std.ascii.eqlIgnoreCase(tz_tok, "GMT") or std.ascii.eqlIgnoreCase(tz_tok, "UTC") or std.ascii.eqlIgnoreCase(tz_tok, "Z")) {
                tz_offset_ms = 0.0;
            } else if (std.mem.startsWith(u8, tz_tok, "GMT+") or std.mem.startsWith(u8, tz_tok, "GMT-") or
                std.mem.startsWith(u8, tz_tok, "UTC+") or std.mem.startsWith(u8, tz_tok, "UTC-") or
                tz_tok[0] == '+' or tz_tok[0] == '-')
            {
                const off_str = if (tz_tok[0] == '+' or tz_tok[0] == '-') tz_tok else tz_tok[3..];
                if (off_str.len < 5) return null;
                const tz_neg = off_str[0] == '-';
                var opos: usize = 1;
                const tz_h = parseDigits(off_str, &opos, 2) orelse return null;
                if (opos < off_str.len and off_str[opos] == ':') opos += 1;
                const tz_m = parseDigits(off_str, &opos, 2) orelse return null;
                if (opos != off_str.len or tz_h > 23 or tz_m > 59) return null;
                const total_ms = @as(f64, @floatFromInt(tz_h * 60 + tz_m)) * ms_per_minute;
                tz_offset_ms = if (tz_neg) -total_ms else total_ms;
            } else {
                return null;
            }
        }
    }
    if (it.next() != null) return null;

    const d = makeDay(@floatFromInt(year), @floatFromInt(month), @floatFromInt(day));
    const t = makeTime(@floatFromInt(hour), @floatFromInt(minute), @floatFromInt(second), 0.0);
    const dt = makeDate(d, t);
    if (!std.math.isFinite(dt)) return null;
    if (tz_offset_ms) |off| return dt - off;
    return utcFromLocal(dt);
}

// ---------------------------------------------------------------- Unit Tests

test "timeClip boundaries and -0" {
    try std.testing.expectEqual(@as(f64, 0.0), timeClip(-0.0));
    try std.testing.expect(!std.math.signbit(timeClip(-0.0)));
    try std.testing.expectEqual(@as(f64, 8.64e15), timeClip(8.64e15));
    try std.testing.expectEqual(@as(f64, -8.64e15), timeClip(-8.64e15));
    try std.testing.expect(std.math.isNan(timeClip(8.64e15 + 1.0)));
    try std.testing.expect(std.math.isNan(timeClip(-8.64e15 - 1.0)));
    try std.testing.expect(std.math.isNan(timeClip(std.math.inf(f64))));
    try std.testing.expect(std.math.isNan(timeClip(std.math.nan(f64))));
}

test "calendar math: epoch, leap years 1900/2000/2100, and BCE dates" {
    // Epoch: 1970-01-01 Thursday
    const epoch = decompose(0.0).?;
    try std.testing.expectEqual(@as(i64, 1970), epoch.year);
    try std.testing.expectEqual(@as(u8, 0), epoch.month);
    try std.testing.expectEqual(@as(u8, 1), epoch.day);
    try std.testing.expectEqual(@as(u8, 4), epoch.weekday);

    // 1900 is NOT a leap year: 1900-02-28 + 1 day = 1900-03-01
    const d1900 = makeDate(makeDay(1900, 1, 29), 0);
    const dec1900 = decompose(d1900).?;
    try std.testing.expectEqual(@as(i64, 1900), dec1900.year);
    try std.testing.expectEqual(@as(u8, 2), dec1900.month); // March
    try std.testing.expectEqual(@as(u8, 1), dec1900.day);

    // 2000 IS a leap year: 2000-02-29 stays Feb 29
    const d2000 = makeDate(makeDay(2000, 1, 29), 0);
    const dec2000 = decompose(d2000).?;
    try std.testing.expectEqual(@as(i64, 2000), dec2000.year);
    try std.testing.expectEqual(@as(u8, 1), dec2000.month); // Feb
    try std.testing.expectEqual(@as(u8, 29), dec2000.day);

    // 2100 is NOT a leap year: 2100-02-29 -> 2100-03-01
    const d2100 = makeDate(makeDay(2100, 1, 29), 0);
    const dec2100 = decompose(d2100).?;
    try std.testing.expectEqual(@as(i64, 2100), dec2100.year);
    try std.testing.expectEqual(@as(u8, 2), dec2100.month);
    try std.testing.expectEqual(@as(u8, 1), dec2100.day);

    // Negative / BCE dates: -000001-12-31T23:59:59.999Z
    const bce = makeDate(makeDay(-1, 11, 31), makeTime(23, 59, 59, 999));
    const dec_bce = decompose(bce).?;
    try std.testing.expectEqual(@as(i64, -1), dec_bce.year);
    try std.testing.expectEqual(@as(u8, 11), dec_bce.month);
    try std.testing.expectEqual(@as(u8, 31), dec_bce.day);
    try std.testing.expectEqual(@as(u8, 23), dec_bce.hour);
    try std.testing.expectEqual(@as(u16, 999), dec_bce.ms);

    // ±8.64e15 extreme round-trips
    const max_dec = decompose(max_time_ms).?;
    try std.testing.expectEqual(@as(i64, 275760), max_dec.year);
    try std.testing.expectEqual(@as(u8, 8), max_dec.month); // September
    try std.testing.expectEqual(@as(u8, 13), max_dec.day);

    const min_dec = decompose(-max_time_ms).?;
    try std.testing.expectEqual(@as(i64, -271821), min_dec.year);
    try std.testing.expectEqual(@as(u8, 3), min_dec.month); // April
    try std.testing.expectEqual(@as(u8, 20), min_dec.day);
}

test "ISO formatting and parsing round-trip" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z", formatISO(&buf, 0.0));
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", formatUTC(&buf, 0.0));
    try std.testing.expectEqual(@as(f64, 0.0), parse("1970-01-01"));
    try std.testing.expectEqual(@as(f64, 0.0), parse("Thu, 01 Jan 1970 00:00:00 GMT"));
    try std.testing.expectEqual(@as(f64, 0.0), parse("1970-01-01T02:00:00.000+02:00"));
    try std.testing.expect(std.math.isNan(parse("-000000-01-01")));
    try std.testing.expect(std.math.isNan(parse("not a date")));
}

test "timezoneOffsetMinutes preserves sub-minute LMT offsets and round-trips utcFromLocal" {
    // +0.0 normalization (never -0.0)
    const zero_off = offsetMinutesFromSeconds(0);
    try std.testing.expectEqual(@as(f64, 0.0), zero_off);
    try std.testing.expect(!std.math.signbit(zero_off));

    // Whole-minute offsets
    try std.testing.expectEqual(@as(f64, -120.0), offsetMinutesFromSeconds(7200));
    try std.testing.expectEqual(@as(f64, 300.0), offsetMinutesFromSeconds(-18000));

    // Historical sub-minute LMT offsets (e.g. Europe/Kyiv +02:02:04 = 7324s, Europe/Paris +00:09:21 = 561s)
    const lmt_offsets = [_]i64{ 7324, 561, 19270, -29578 };
    const sample_local = [_]f64{ -2211667200000.0, -2208988800001.0, -2208988800000.0 };
    for (lmt_offsets) |off_sec| {
        const gto = offsetMinutesFromSeconds(off_sec);
        for (sample_local) |expected_local| {
            const actual_utc = expected_local - @as(f64, @floatFromInt(off_sec)) * ms_per_second;
            try std.testing.expectEqual(expected_local, actual_utc - gto * ms_per_minute);
        }
    }

    // Host timezone round-trip for S15.9.3.1_A5_T1..T6 dates (1899..2100)
    const relative_cases = [_]f64{
        -2211667200000.0, -2209075200000.0, -2208992400000.0, -2208988860000.0,
        -2208988801000.0, -2208988800001.0, -2208988800000.0, -2678400000.0,
        -86400000.0,      -3600000.0,       -60000.0,         -1000.0,
        -1.0,             0.0,              944006400000.0,   946684800000.0,
        4099766400000.0,  4102444800000.0,
    };
    for (relative_cases) |expected_local| {
        const actual_utc = timeClip(utcFromLocal(expected_local));
        const local_offset = timezoneOffsetMinutes(actual_utc) * ms_per_minute;
        try std.testing.expectEqual(expected_local, actual_utc - local_offset);
    }
}
