//! zqjs library entry point. M3: frontend (parse → resolve → dump) and the
//! tree-walking interpreter. M4: bytecode compiler, verifier and disassembler. M5: the VM.

pub const ast = @import("frontend/ast.zig");
pub const Diagnostic = @import("frontend/diag.zig").Diagnostic;
pub const Feature = @import("frontend/diag.zig").Feature;
pub const Limits = @import("limits.zig").Limits;
pub const Limit = @import("limits.zig").Limit;
pub const parse = @import("frontend/parser.zig").parse;
pub const resolve = @import("frontend/resolver.zig").resolve;
pub const Resolution = @import("frontend/resolver.zig").Resolution;
pub const dump = @import("frontend/dump.zig");
pub const ops = @import("runtime/ops.zig");
pub const Runtime = @import("runtime/runtime.zig").Runtime;
pub const ErrorName = @import("runtime/runtime.zig").ErrorName;
pub const interpret = @import("interp/treewalk.zig").run;
pub const bytecode = @import("bytecode/bytecode.zig");
pub const compile = @import("bytecode/compiler.zig").compile;
pub const verify = @import("bytecode/verify.zig");
pub const disassemble = @import("bytecode/disasm.zig").disassemble;
pub const Heap = @import("runtime/heap.zig").Heap;
pub const runSource = @import("run.zig").runSource;
pub const RunMode = @import("run.zig").Mode;
pub const RunOptions = @import("run.zig").Options;
pub const Engine = @import("run.zig").Engine;
pub const Vm = @import("vm/vm.zig").Vm;
pub const Value = @import("runtime/value.zig").Value;

// Small unit tests live next to the code they test (`test` blocks in each file);
// integration, golden and fuzz tests live in tests/ (root: tests/all.zig).
test {
    _ = @import("frontend/token.zig");
    _ = @import("frontend/lexer.zig");
    _ = @import("frontend/diag.zig");
    _ = @import("frontend/parser.zig");
    _ = @import("frontend/resolver.zig");
    _ = @import("runtime/heap.zig");
    _ = @import("runtime/ops.zig");
    _ = @import("runtime/pow.zig");
    _ = @import("bytecode/bytecode.zig");
    _ = @import("bytecode/verify.zig");
}
