//! Umbrella integration test suite for `zig build test`.
//! Keeps `zqjs_internal` compiled once instead of eleven times; individual suites
//! remain runnable via `zig build test-<name>`.

comptime {
    _ = @import("gc_test.zig");
    _ = @import("interpreter_test.zig");
    _ = @import("bytecode_test.zig");
    _ = @import("diff_test.zig");
    _ = @import("vm_test.zig");
    _ = @import("syntax_test.zig");
    _ = @import("ops_test.zig");
    _ = @import("frontend_test.zig");
    _ = @import("regex_test.zig");
    _ = @import("repl_test.zig");
    _ = @import("module_test.zig");
}
