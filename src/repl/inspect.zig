//! Thin re-export of the cycle-safe, depth-bounded JS value inspector (`src/runtime/inspect.zig`).

const runtime_inspect = @import("../runtime/inspect.zig");

pub const Options = runtime_inspect.Options;
pub const inspect = runtime_inspect.inspect;
