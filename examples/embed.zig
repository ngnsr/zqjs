//! Embedding example: shows how an embedder integrates ZQJS into an event or game loop.
//!
//! Demonstrates:
//! - Creating a Runtime with custom resource limits and output writer.
//! - Registering host native functions (`defineGlobalFunction`) with a borrowed host context.
//! - Retaining JS function/object handles across frames with `dup()` and `defer` cleanup.
//! - Complete JS → native → JS callback round trips (`Runtime.call` inside a `NativeFn` and
//!   at top level) and ownership transfer via `NativeOut.result`.
//! - Cooperative multitasking: running two separate executions interleaved in step slices
//!   across frames, without blocking the host loop.
//! - Handling completion, suspension, and errors without panicking.
//! - Lifecycle and clean destruction on every exit path.
//!
//! Run with: `zig build example`

const std = @import("std");
const zqjs = @import("zqjs");

const HostBridge = struct {
    /// Retained JS object and callback closure (`dup`ed from temporary native argument handles).
    guard_obj: ?*zqjs.Handle = null,
    on_waypoint: ?*zqjs.Handle = null,
    bonus_per_waypoint: f64 = 10,

    fn deinit(self: *HostBridge) void {
        if (self.on_waypoint) |h| {
            h.release();
            self.on_waypoint = null;
        }
        if (self.guard_obj) |o| {
            o.release();
            self.guard_obj = null;
        }
    }

    /// Host native: `registerWaypointHook(guardObj, fn)` — retains both `guardObj` and `fn`
    /// via `dup()` so they outlive the callback and survive GC between frames (D50).
    fn registerWaypointHook(
        rt: *zqjs.Runtime,
        raw_ctx: ?*anyopaque,
        _: ?*zqjs.Handle,
        args: []const *zqjs.Handle,
        _: *zqjs.NativeOut,
    ) zqjs.NativeError!void {
        const self: *HostBridge = @ptrCast(@alignCast(raw_ctx.?));
        if (args.len < 2 or args[0].kind() != .object or args[1].kind() != .function) {
            const msg = [_]u16{ 'e', 'x', 'p', 'e', 'c', 't', 'e', 'd', ' ', '(', 'o', 'b', 'j', ',', ' ', 'f', 'n', ')' };
            rt.throwJs(.TypeError, &msg);
            return error.Thrown;
        }
        const dup_obj = try args[0].dup();
        errdefer dup_obj.release();
        const dup_fn = try args[1].dup();

        if (self.guard_obj) |old| old.release();
        if (self.on_waypoint) |old| old.release();
        self.guard_obj = dup_obj;
        self.on_waypoint = dup_fn;
    }

    /// Host native: `notifyWaypoint(waypoint)` — calls back into the retained JS hook
    /// with the retained `guard_obj` as `this` via `rt.call` (JS → native → JS round trip),
    /// and transfers the result handle to the engine via `out.result` (D50, D51, D53).
    fn notifyWaypoint(
        rt: *zqjs.Runtime,
        raw_ctx: ?*anyopaque,
        _: ?*zqjs.Handle,
        args: []const *zqjs.Handle,
        out: *zqjs.NativeOut,
    ) zqjs.NativeError!void {
        const self: *HostBridge = @ptrCast(@alignCast(raw_ctx.?));
        const hook = self.on_waypoint orelse return;
        const guard = self.guard_obj orelse return;
        if (args.len < 1) return;

        const bonus = try rt.newNumber(self.bonus_per_waypoint);
        defer bonus.release();

        // Call back into JS with `guard` as `this`, plus `(waypoint, bonus)`.
        const score = rt.call(hook, guard, &.{ args[0], bonus }, null) catch |e| return switch (e) {
            error.OutputFailed => error.HostError,
            else => |ne| ne,
        };
        // Ownership of `score` moves to the engine via `out.result` (D50).
        out.result = score;
    }
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var out_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    try out.writeAll("=== ZQJS Embedding Example: Interleaved Executions & Native Callbacks ===\n\n");

    // 1. Create a runtime with resource limits and an output writer for `print`.
    const rt = try zqjs.Runtime.create(gpa, .{
        .limits = .{
            .max_heap_bytes = 4 * 1024 * 1024,
            .max_steps = 100_000,
        },
        .output = out,
    });
    defer rt.destroy();

    // 2. Register host native functions with a borrowed context struct.
    //    `bridge.deinit()` runs before `rt.destroy()` on every exit path.
    var bridge: HostBridge = .{};
    defer bridge.deinit();

    try rt.defineGlobalFunction("registerWaypointHook", HostBridge.registerWaypointHook, &bridge);
    try rt.defineGlobalFunction("notifyWaypoint", HostBridge.notifyWaypoint, &bridge);

    // 3. Compile two independent JavaScript programs.
    // Actor 1: Registers a JS callback hook, then patrols waypoints and invokes the host
    // native `notifyWaypoint`, which calls back into JS to update and score the guard.
    const actor_src =
        \\let guard = { name: 'Alpha', score: 0 };
        \\registerWaypointHook(guard, function(wp, bonus) {
        \\  this.score = this.score + wp * bonus;
        \\  return this.score;
        \\});
        \\let waypoint = 1;
        \\while (waypoint <= 3) {
        \\  let total = notifyWaypoint(waypoint);
        \\  print('  [Guard] reached waypoint', waypoint, '-> score:', total);
        \\  waypoint = waypoint + 1;
        \\}
        \\print('  [Guard] patrol route complete. Final score:', guard.score);
    ;

    // Actor 2: Generates procedural game loot / numbers.
    const loot_src =
        \\let seed = 42;
        \\for (let i = 1; i <= 3; i = i + 1) {
        \\  seed = (seed * 1103515245 + 12345) % 2147483648;
        \\  print('  [LootGen] generated item with power', seed % 100);
        \\}
        \\print('  [LootGen] loot generation finished.');
    ;

    var diag: zqjs.Diagnostic = .{};
    const actor_prog = rt.compile("guard.js", actor_src, &diag) catch |e| {
        try out.print("Failed to compile guard script: {s}\n", .{@errorName(e)});
        try diag.render(actor_src, "guard.js", out);
        return 1;
    };
    defer actor_prog.destroy();

    const loot_prog = rt.compile("loot.js", loot_src, &diag) catch |e| {
        try out.print("Failed to compile loot script: {s}\n", .{@errorName(e)});
        try diag.render(loot_src, "loot.js", out);
        return 1;
    };
    defer loot_prog.destroy();

    // 3. Start two independent executions on the same runtime.
    // They share the heap and realm, but each has its own VM state and top-level variables.
    const ex_actor = try rt.start(actor_prog);
    defer ex_actor.destroy();

    const ex_loot = try rt.start(loot_prog);
    defer ex_loot.destroy();

    // 4. Simulate a host game/event loop with a budget slice per frame (e.g. 10 steps per actor).
    const slice_steps = 10;
    var frame: usize = 1;
    var actor_status: zqjs.Status = .suspended;
    var loot_status: zqjs.Status = .suspended;

    try out.writeAll("Starting game loop:\n");

    var failure: zqjs.Failure = .{};
    while (actor_status == .suspended or loot_status == .suspended) : (frame += 1) {
        try out.print("\n--- Frame {d} ---\n", .{frame});

        if (actor_status == .suspended) {
            actor_status = ex_actor.@"resume"(slice_steps, &failure) catch |err| {
                try out.print("Guard script error: {s} - {s}\n", .{ @errorName(err), failure.message() });
                return 1;
            };
            if (actor_status == .suspended) {
                try out.writeAll("  [Host] Guard execution slice ended (suspended until next frame)\n");
            }
        }

        if (loot_status == .suspended) {
            loot_status = ex_loot.@"resume"(slice_steps, &failure) catch |err| {
                try out.print("Loot script error: {s} - {s}\n", .{ @errorName(err), failure.message() });
                return 1;
            };
            if (loot_status == .suspended) {
                try out.writeAll("  [Host] LootGen execution slice ended (suspended until next frame)\n");
            }
        }
    }

    try out.print("\nAll scripts completed in {d} frames.\n", .{frame - 1});

    // 5. Force a GC collection, then invoke the retained JS hook from the host at top
    //    level (`Runtime.call`) with the retained `guard_obj` as `this`, proving both
    //    `dup`ed handles survived execution teardown and garbage collection.
    rt.collectGarbage();
    if (bridge.on_waypoint) |hook| {
        const wp = try rt.newNumber(4);
        defer wp.release();
        const bonus = try rt.newNumber(5);
        defer bonus.release();
        const post_score = rt.call(hook, bridge.guard_obj, &.{ wp, bonus }, &failure) catch |err| {
            try out.print("Post-loop callback error: {s} - {s}\n", .{ @errorName(err), failure.message() });
            return 1;
        };
        defer post_score.release();
        try out.print("Post-GC host callback (`rt.call`) updated score to: {d}\n", .{post_score.number().?});
    }

    const mem = rt.memory();
    try out.print("Runtime memory: {d} bytes active, {d} bytes peak, {d} GC collections.\n", .{
        mem.bytes,
        mem.peak,
        mem.collections,
    });
    return 0;
}
