//! zqjs library entry point. M1 exposes the frontend only.

pub const ast = @import("frontend/ast.zig");
pub const Diagnostic = @import("frontend/diag.zig").Diagnostic;
pub const Feature = @import("frontend/diag.zig").Feature;
pub const Limits = @import("limits.zig").Limits;
pub const Limit = @import("limits.zig").Limit;
pub const parser = @import("frontend/parser.zig");
pub const parse = parser.parse;

test {
    _ = @import("frontend/token.zig");
    _ = @import("frontend/lexer.zig");
    _ = @import("frontend/diag.zig");
    _ = @import("frontend/parser.zig");
}
