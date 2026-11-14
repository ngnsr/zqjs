//! Root of the integration tests. Unit tests stay next to the code (src/**);
//! everything here goes through the public `zqjs` module.
//!
//!   frontend_test.zig     allocation-failure paths and fuzzing of parse → resolve → dump
//!   interpreter_test.zig  limits, allocation failures, exception ownership, fuzzing of runs
//!   syntax_test.zig       syntax/cases.jsonl: outcome + resolved dump for each source
//!   ops_test.zig          ops/*.jsonl: conversions and operators vs node, bit for bit
//!   diff_test.zig         diff/*.js: whole programs, output must equal node's (diff/*.out)
//!   bytecode_test.zig     compiler + verifier over all programs, snapshots, limits, fuzzing
//!
//! Data files are generated or checked with node by the scripts in harness/.

test {
    _ = @import("frontend_test.zig");
    _ = @import("interpreter_test.zig");
    _ = @import("syntax_test.zig");
    _ = @import("ops_test.zig");
    _ = @import("diff_test.zig");
    _ = @import("bytecode_test.zig");
}
