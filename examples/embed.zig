//! Embedding example: shows how an embedder integrates ZQJS into an event or game loop.
//!
//! Demonstrates:
//! - Creating a Runtime with custom resource limits and output writer.
//! - Compiling JavaScript programs ahead of time.
//! - Cooperative multitasking: running two separate executions interleaved in step slices
//!   across frames, without blocking the host loop.
//! - Handling completion, suspension, and errors without panicking.
//! - Lifecycle and clean destruction.
//!
//! Run with: `zig build example`

const std = @import("std");
const zqjs = @import("zqjs");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var out_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    try out.writeAll("=== ZQJS Embedding Example: Interleaved Executions ===\n\n");

    // 1. Create a runtime with resource limits and an output writer for `print`.
    const rt = try zqjs.Runtime.create(gpa, .{
        .limits = .{
            .max_heap_bytes = 4 * 1024 * 1024,
            .max_steps = 100_000,
        },
        .output = out,
    });
    defer rt.destroy();

    // 2. Compile two independent JavaScript programs.
    // Actor 1: Patrols waypoints in a loop.
    const actor_src =
        \\let waypoint = 1;
        \\while (waypoint <= 3) {
        \\  print('  [Guard] patrolling toward waypoint', waypoint);
        \\  waypoint = waypoint + 1;
        \\}
        \\print('  [Guard] patrol route complete.');
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
    const mem = rt.memory();
    try out.print("Runtime memory: {d} bytes active, {d} bytes peak, {d} GC collections.\n", .{
        mem.bytes,
        mem.peak,
        mem.collections,
    });
    return 0;
}
