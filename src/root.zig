//! zqjs library entry point. M3: frontend (parse → resolve → dump) and the
//! tree-walking interpreter. M4: bytecode compiler, verifier and disassembler. M5: the VM.

pub const ast = @import("frontend/ast.zig");
pub const Diagnostic = @import("frontend/diag.zig").Diagnostic;
pub const Feature = @import("frontend/diag.zig").Feature;
pub const Limits = @import("limits.zig").Limits;
pub const Limit = @import("limits.zig").Limit;
pub const limits = @import("limits.zig");
pub const regex = @import("regex.zig");
pub const parse = @import("frontend/parser.zig").parse;
pub const resolve = @import("frontend/resolver.zig").resolve;
pub const Resolution = @import("frontend/resolver.zig").Resolution;
pub const dump = @import("frontend/dump.zig");
pub const ops = @import("runtime/ops.zig");
pub const date = @import("runtime/date.zig");
pub const bigint = @import("runtime/bigint.zig");
pub const Runtime = @import("runtime/runtime.zig").Runtime;
pub const ErrorName = @import("runtime/runtime.zig").ErrorName;
pub const interpret = @import("interp/machine.zig").run;
pub const bytecode = @import("bytecode/bytecode.zig");
pub const compile = @import("bytecode/compiler.zig").compile;
pub const verify = @import("bytecode/verify.zig");
pub const disassemble = @import("bytecode/disasm.zig").disassemble;
pub const Heap = @import("runtime/heap.zig").Heap;
pub const heap = @import("runtime/heap.zig");
pub const runtime = @import("runtime/runtime.zig");
pub const builtins = @import("runtime/builtins.zig");
pub const object = @import("runtime/object.zig");
pub const handles = @import("runtime/handles.zig");
pub const module = @import("runtime/module.zig");
pub const runSource = @import("run.zig").runSource;
pub const runModule = @import("run.zig").runModule;
pub const RunMode = @import("run.zig").Mode;
pub const RunOptions = @import("run.zig").Options;
pub const Engine = @import("run.zig").Engine;
pub const Vm = @import("vm/vm.zig").Vm;
pub const Value = @import("runtime/value.zig").Value;
pub const Native = @import("runtime/value.zig").Native;
pub const repl = struct {
    pub const session = @import("repl/session.zig");
    pub const inspect = @import("repl/inspect.zig");
    pub const complete = @import("repl/complete.zig");
    pub const editor = @import("repl/editor.zig");
    pub const Session = session.Session;
};
pub const debug = struct {
    pub const debugger = @import("debug/debugger.zig");
    pub const inspector = @import("debug/inspector.zig");
    pub const Debugger = debugger.Debugger;
};

// Small unit tests live next to the code they test (`test` blocks in each file);
// integration, golden and fuzz tests live in tests/ (one test binary per file, build.zig).
test {
    _ = @import("limits.zig");
    _ = @import("frontend/token.zig");
    _ = @import("frontend/lexer.zig");
    _ = @import("frontend/number.zig");
    _ = @import("frontend/diag.zig");
    _ = @import("frontend/parser.zig");
    _ = @import("frontend/resolver.zig");
    _ = @import("runtime/heap.zig");
    _ = @import("runtime/ops.zig");
    _ = @import("runtime/date.zig");
    _ = @import("runtime/bigint.zig");
    _ = @import("runtime/pow.zig");
    _ = @import("bytecode/bytecode.zig");
    _ = @import("bytecode/verify.zig");
    _ = @import("interp/machine.zig");
    _ = @import("debug/inspector.zig");
    _ = @import("debug/debugger.zig");
}
