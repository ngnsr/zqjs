//! zqjs library entry point. M2 exposes the frontend only: parse → resolve → dump.

pub const ast = @import("frontend/ast.zig");
pub const Diagnostic = @import("frontend/diag.zig").Diagnostic;
pub const Feature = @import("frontend/diag.zig").Feature;
pub const Limits = @import("limits.zig").Limits;
pub const Limit = @import("limits.zig").Limit;
pub const parse = @import("frontend/parser.zig").parse;
pub const resolve = @import("frontend/resolver.zig").resolve;
pub const Resolution = @import("frontend/resolver.zig").Resolution;
pub const dump = @import("frontend/dump.zig");

test {
    _ = @import("frontend/token.zig");
    _ = @import("frontend/lexer.zig");
    _ = @import("frontend/diag.zig");
    _ = @import("frontend/parser.zig");
    _ = @import("frontend/resolver.zig");
    _ = @import("frontend/frontend_test.zig");
}
