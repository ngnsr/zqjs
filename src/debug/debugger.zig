//! M11 Bytecode Debugger layered purely on top of `Vm.step()` (DESIGN_DECISIONS D35).
//! Zero overhead in `Vm.runLoop()`: the VM hot loop is untouched and knows nothing about
//! breakpoints or stepping modes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const bc = @import("../bytecode/bytecode.zig");
const Op = bc.Op;
const Proto = bc.Proto;
const disasm = @import("../bytecode/disasm.zig");
const vm_mod = @import("../vm/vm.zig");
const Vm = vm_mod.Vm;
const Frame = vm_mod.Frame;
const Slot = vm_mod.Slot;
const rt_mod = @import("../runtime/runtime.zig");
const Error = rt_mod.Error;
const Value = @import("../runtime/value.zig").Value;
const heap = @import("../runtime/heap.zig");
pub const inspector = @import("inspector.zig");

pub const BreakpointError = error{
    InvalidPc,
    InvalidProto,
    OutOfMemory,
};

pub const Breakpoint = struct {
    id: u32,
    proto: *const Proto,
    /// Deterministic depth-first index in the script's Proto tree (0 = script), if reachable.
    proto_id: ?u32,
    pc: u32,
    hit_count: u64 = 0,
    enabled: bool = true,
};

pub const ProtoInfo = struct {
    id: u32,
    proto: *const Proto,
    name: []const u8,
    is_script: bool,
    code_len: usize,
    param_count: u32,
    slot_count: u32,
};

pub const StopReason = union(enum) {
    step,
    breakpoint: u32,
    halted,
    awaiting,
};

pub const LocalSlot = struct {
    index: u32,
    is_param: bool,
    is_captured: bool,
    /// `null` when the binding is uninitialized (TDZ).
    value: ?Value,
};

pub const CaptureSlot = struct {
    index: u32,
    /// `null` when the captured cell is still in TDZ.
    value: ?Value,
};

/// Zero-allocation read-only view of an active call frame (valid until the next `Vm.step()`).
pub const FrameView = struct {
    /// Frame index in `vm.frames` (`0` = script, `frameCount() - 1` = currently executing frame).
    depth: usize,
    is_top: bool,
    proto: *const Proto,
    proto_id: ?u32,
    function_name: []const u8,
    pc: u32,
    current_op: ?Op,
    param_count: u32,
    param_slot: u32,
    argc: u32,
    this_value: ?Value,
    raw_locals: []const Slot,
    operands: []const Value,
    closure: ?*const heap.Closure,

    pub fn localSlot(self: FrameView, index: u32) ?LocalSlot {
        if (index >= self.raw_locals.len) return null;
        return decodeSlot(self.proto, index, self.raw_locals[index]);
    }
};

/// Owned snapshot of an active call frame, safe to retain across subsequent steps and
/// `-Dstack-stress` stack relocations.
pub const FrameSnapshot = struct {
    depth: usize,
    is_top: bool,
    proto: *const Proto,
    proto_id: ?u32,
    function_name: []const u8,
    pc: u32,
    current_op: ?Op,
    disasm_line: []u8,
    locals: []LocalSlot,
    params: []LocalSlot,
    captures: []CaptureSlot,
    operands: []Value,
    this_value: ?Value,

    pub fn deinit(self: *FrameSnapshot, alloc: Allocator) void {
        alloc.free(self.disasm_line);
        alloc.free(self.locals);
        alloc.free(self.params);
        alloc.free(self.captures);
        alloc.free(self.operands);
    }
};

/// Owned stack trace ordered top-of-stack first (`frames[0]` is the currently executing frame).
pub const StackTrace = struct {
    frames: []FrameSnapshot,

    pub fn deinit(self: *StackTrace, alloc: Allocator) void {
        for (self.frames) |*f| f.deinit(alloc);
        alloc.free(self.frames);
    }
};

pub const GcKind = enum { minor, major };

pub const GcReport = struct {
    kind: GcKind,
    bytes_before: usize,
    bytes_after: usize,
    freed_bytes: usize,
    live_objects_before: usize,
    live_objects_after: usize,
    verified: bool,
};

pub const Debugger = struct {
    gpa: Allocator,
    vm: *Vm,
    breakpoints: std.ArrayList(Breakpoint) = .empty,
    next_bp_id: u32 = 1,
    /// Set after stopping on a breakpoint so the next `continueUntilBreakpoint` executes
    /// the paused instruction once instead of re-triggering on the same PC before advancing.
    skip_bp_once: bool = false,

    pub fn init(gpa: Allocator, vm: *Vm) Debugger {
        return .{ .gpa = gpa, .vm = vm };
    }

    pub fn deinit(self: *Debugger) void {
        self.breakpoints.deinit(self.gpa);
        self.* = undefined;
    }

    // ---- Proto tree lookup (deterministic depth-first IDs: 0 = script)

    pub fn protoById(self: *const Debugger, proto_id: u32) ?*const Proto {
        var cur: u32 = 0;
        return findProtoByIdRec(self.vm.scriptProto(), proto_id, &cur);
    }

    pub fn protoId(self: *const Debugger, target: *const Proto) ?u32 {
        var cur: u32 = 0;
        return findProtoIdRec(self.vm.scriptProto(), target, &cur);
    }

    pub fn findProtoByName(self: *const Debugger, name: []const u8) ?*const Proto {
        return findProtoByNameRec(self.vm.scriptProto(), name);
    }

    pub fn listProtos(self: *const Debugger, alloc: Allocator) Allocator.Error![]ProtoInfo {
        var list: std.ArrayList(ProtoInfo) = .empty;
        errdefer list.deinit(alloc);
        var cur: u32 = 0;
        try collectProtosRec(alloc, self.vm.scriptProto(), &cur, &list);
        return list.toOwnedSlice(alloc);
    }

    // ---- Breakpoints

    /// Returns true iff `pc` is an exact instruction boundary within `proto.code`.
    pub fn isValidPc(proto: *const Proto, pc: u32) bool {
        if (pc >= proto.code.len) return false;
        var offset: usize = 0;
        while (offset < proto.code.len) {
            if (offset == pc) return true;
            const byte = proto.code[offset];
            if (byte >= Op.count) return false;
            const op: Op = @fromBackingInt(@intCast(byte));
            const size = op.size();
            if (size > proto.code.len - offset) return false;
            offset += size;
        }
        return false;
    }

    /// Sets a breakpoint at `(proto, pc)` and returns its stable ID.
    /// Setting at an existing `(proto, pc)` re-enables and returns its existing ID.
    pub fn setBreakpoint(self: *Debugger, proto: *const Proto, pc: u32) BreakpointError!u32 {
        if (!isValidPc(proto, pc)) return error.InvalidPc;
        for (self.breakpoints.items) |*bp| {
            if (bp.proto == proto and bp.pc == pc) {
                bp.enabled = true;
                return bp.id;
            }
        }
        const id = self.next_bp_id;
        self.next_bp_id += 1;
        try self.breakpoints.append(self.gpa, .{
            .id = id,
            .proto = proto,
            .proto_id = self.protoId(proto),
            .pc = pc,
        });
        return id;
    }

    pub fn setBreakpointByProtoId(self: *Debugger, proto_id: u32, pc: u32) BreakpointError!u32 {
        const proto = self.protoById(proto_id) orelse return error.InvalidProto;
        return self.setBreakpoint(proto, pc);
    }

    pub fn setFunctionBreakpoint(self: *Debugger, name: []const u8) BreakpointError!u32 {
        const proto = self.findProtoByName(name) orelse return error.InvalidProto;
        return self.setBreakpoint(proto, 0);
    }

    pub fn clearBreakpoint(self: *Debugger, id: u32) bool {
        for (self.breakpoints.items, 0..) |bp, i| {
            if (bp.id == id) {
                _ = self.breakpoints.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn clearBreakpointAt(self: *Debugger, proto: *const Proto, pc: u32) bool {
        for (self.breakpoints.items, 0..) |bp, i| {
            if (bp.proto == proto and bp.pc == pc) {
                _ = self.breakpoints.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn clearAllBreakpoints(self: *Debugger) void {
        self.breakpoints.clearRetainingCapacity();
        self.skip_bp_once = false;
    }

    pub fn setBreakpointEnabled(self: *Debugger, id: u32, enabled: bool) bool {
        for (self.breakpoints.items) |*bp| {
            if (bp.id == id) {
                bp.enabled = enabled;
                return true;
            }
        }
        return false;
    }

    pub fn listBreakpoints(self: *const Debugger) []const Breakpoint {
        return self.breakpoints.items;
    }

    pub fn getBreakpoint(self: *const Debugger, id: u32) ?Breakpoint {
        for (self.breakpoints.items) |bp| {
            if (bp.id == id) return bp;
        }
        return null;
    }

    fn matchBreakpoint(self: *Debugger, proto: *const Proto, pc: u32) ?u32 {
        for (self.breakpoints.items) |*bp| {
            if (bp.enabled and bp.proto == proto and bp.pc == pc) {
                bp.hit_count += 1;
                self.skip_bp_once = true;
                return bp.id;
            }
        }
        return null;
    }

    // ---- Stepping modes

    /// Executes a single bytecode instruction via `Vm.step()`.
    pub fn stepInstruction(self: *Debugger) Error!StopReason {
        self.skip_bp_once = false;
        return switch (try self.vm.step()) {
            .running => .step,
            .halted => .halted,
            .awaiting => .awaiting,
        };
    }

    /// Executes a single bytecode instruction, entering any called JS function.
    pub fn stepInto(self: *Debugger) Error!StopReason {
        return self.stepInstruction();
    }

    /// Steps over the current instruction: if it enters a deeper JS call frame, continues
    /// until `call_depth <= start_depth` (or an enabled breakpoint is hit inside the callee).
    pub fn stepOver(self: *Debugger) Error!StopReason {
        self.skip_bp_once = false;
        if (self.vm.fault) |e| return e;
        if (self.vm.halted) return .halted;

        const start_depth = self.vm.frames.items.len;
        switch (try self.vm.step()) {
            .running => {},
            .halted => return .halted,
            .awaiting => return .awaiting,
        }

        while (self.vm.frames.items.len > start_depth) {
            if (self.matchBreakpoint(self.vm.proto(), self.vm.pc)) |bp_id| {
                return .{ .breakpoint = bp_id };
            }
            switch (try self.vm.step()) {
                .running => {},
                .halted => return .halted,
                .awaiting => return .awaiting,
            }
        }
        return .step;
    }

    /// Continues execution until the current frame returns (`call_depth < start_depth`),
    /// or until an enabled breakpoint is hit, or the VM halts/awaits.
    pub fn stepOut(self: *Debugger) Error!StopReason {
        self.skip_bp_once = false;
        if (self.vm.fault) |e| return e;
        if (self.vm.halted) return .halted;

        const start_depth = self.vm.frames.items.len;
        while (true) {
            switch (try self.vm.step()) {
                .running => {},
                .halted => return .halted,
                .awaiting => return .awaiting,
            }
            if (self.vm.frames.items.len < start_depth) return .step;
            if (self.matchBreakpoint(self.vm.proto(), self.vm.pc)) |bp_id| {
                return .{ .breakpoint = bp_id };
            }
        }
    }

    /// Continues execution until an enabled breakpoint is hit, or the VM halts/awaits.
    /// If paused at a breakpoint on entry, executes that instruction once before checking again.
    pub fn continueUntilBreakpoint(self: *Debugger) Error!StopReason {
        if (self.vm.fault) |e| return e;
        if (self.vm.halted) return .halted;

        if (self.skip_bp_once) {
            self.skip_bp_once = false;
        } else if (self.matchBreakpoint(self.vm.proto(), self.vm.pc)) |bp_id| {
            return .{ .breakpoint = bp_id };
        }

        while (true) {
            switch (try self.vm.step()) {
                .running => {},
                .halted => return .halted,
                .awaiting => return .awaiting,
            }
            if (self.matchBreakpoint(self.vm.proto(), self.vm.pc)) |bp_id| {
                return .{ .breakpoint = bp_id };
            }
        }
    }

    // ---- Frame & Stack Inspector

    pub fn frameCount(self: *const Debugger) usize {
        return self.vm.frames.items.len;
    }

    pub fn operands(self: *const Debugger) []const Value {
        return self.vm.operands();
    }

    /// Returns a zero-allocation view of frame `index` (`0` = script, `frameCount()-1` = top).
    pub fn frameView(self: *const Debugger, index: usize) ?FrameView {
        const frames = self.vm.frames.items;
        if (index >= frames.len) return null;
        const f = frames[index];
        const is_top = (index == frames.len - 1);
        const pc: u32 = if (is_top) self.vm.pc else frames[index + 1].return_pc;
        const op: ?Op = opcodeAt(f.proto, pc);

        const locals_start = @min(@as(usize, f.locals_base), self.vm.locals_len);
        const locals_end = @min(locals_start + f.proto.slot_count, self.vm.locals_len);

        const op_start = @min(@as(usize, f.stack_base), self.vm.sp);
        const op_end_raw: usize = if (is_top) self.vm.sp else frames[index + 1].stack_base;
        const op_end = @max(op_start, @min(op_end_raw, self.vm.sp));

        return .{
            .depth = index,
            .is_top = is_top,
            .proto = f.proto,
            .proto_id = self.protoId(f.proto),
            .function_name = protoDisplayName(f.proto),
            .pc = pc,
            .current_op = op,
            .param_count = f.proto.param_count,
            .param_slot = f.proto.param_slot,
            .argc = f.argc,
            .this_value = f.thisVal(),
            .raw_locals = self.vm.locals[locals_start..locals_end],
            .operands = self.vm.stack[op_start..op_end],
            .closure = f.closure,
        };
    }

    pub fn currentFrameView(self: *const Debugger) ?FrameView {
        if (self.vm.frames.items.len == 0) return null;
        return self.frameView(self.vm.frames.items.len - 1);
    }

    pub fn disassembleFrame(self: *const Debugger, index: usize, w: *Writer) Writer.Error!void {
        const view = self.frameView(index) orelse return;
        if (view.current_op != null) {
            try disasm.instruction(view.proto.*, view.pc, w);
        } else {
            try w.print("  {d:>5}  <end>", .{view.pc});
        }
    }

    /// Captures an owned snapshot of frame `index`, including disassembly line, locals,
    /// params, closure captures, and operand stack.
    pub fn captureFrame(self: *const Debugger, alloc: Allocator, index: usize) Allocator.Error!?FrameSnapshot {
        const view = self.frameView(index) orelse return null;

        var line_out: Writer.Allocating = .init(alloc);
        errdefer line_out.deinit();
        if (view.current_op != null) {
            disasm.instruction(view.proto.*, view.pc, &line_out.writer) catch return error.OutOfMemory;
        } else {
            line_out.writer.print("  {d:>5}  <end>", .{view.pc}) catch return error.OutOfMemory;
        }
        const disasm_line = try line_out.toOwnedSlice();
        errdefer alloc.free(disasm_line);

        const locals = try alloc.alloc(LocalSlot, view.raw_locals.len);
        errdefer alloc.free(locals);
        for (view.raw_locals, 0..) |slot, i| {
            locals[i] = decodeSlot(view.proto, @intCast(i), slot);
        }

        const p_start = @min(@as(usize, view.param_slot), locals.len);
        const p_end = @min(p_start + view.param_count, locals.len);
        const params = try alloc.dupe(LocalSlot, locals[p_start..p_end]);
        errdefer alloc.free(params);

        var captures_list: std.ArrayList(CaptureSlot) = .empty;
        errdefer captures_list.deinit(alloc);
        if (view.closure) |cl| {
            switch (cl.impl) {
                .vm => |vm_cl| {
                    for (vm_cl.captures, 0..) |cell, i| {
                        try captures_list.append(alloc, .{ .index = @intCast(i), .value = cell.value });
                    }
                },
                else => {},
            }
        }
        const captures = try captures_list.toOwnedSlice(alloc);
        errdefer alloc.free(captures);

        const ops_copy = try alloc.dupe(Value, view.operands);
        errdefer alloc.free(ops_copy);

        return .{
            .depth = view.depth,
            .is_top = view.is_top,
            .proto = view.proto,
            .proto_id = view.proto_id,
            .function_name = view.function_name,
            .pc = view.pc,
            .current_op = view.current_op,
            .disasm_line = disasm_line,
            .locals = locals,
            .params = params,
            .captures = captures,
            .operands = ops_copy,
            .this_value = view.this_value,
        };
    }

    /// Captures all active frames ordered top-of-stack first (`frames[0]` is active frame).
    pub fn captureStackTrace(self: *const Debugger, alloc: Allocator) Allocator.Error!StackTrace {
        const count = self.vm.frames.items.len;
        var list: std.ArrayList(FrameSnapshot) = .empty;
        errdefer {
            for (list.items) |*f| f.deinit(alloc);
            list.deinit(alloc);
        }
        var i: usize = count;
        while (i > 0) {
            i -= 1;
            const snap = (try self.captureFrame(alloc, i)).?;
            try list.append(alloc, snap);
        }
        return .{ .frames = try list.toOwnedSlice(alloc) };
    }

    // ---- Heap Browser & Manual GC

    pub fn heapStats(self: *const Debugger) inspector.HeapStats {
        return inspector.inspectHeap(&self.vm.rt.heap);
    }

    pub fn inspectValue(
        self: *const Debugger,
        alloc: Allocator,
        v: Value,
        opts: inspector.InspectOptions,
    ) Allocator.Error!inspector.ValueInspection {
        _ = self;
        return inspector.inspectValue(alloc, v, opts);
    }

    pub fn formatValue(
        self: *const Debugger,
        v: Value,
        w: *Writer,
        opts: inspector.InspectOptions,
    ) (Allocator.Error || Writer.Error)!void {
        return inspector.formatValue(self.gpa, v, w, opts);
    }

    /// Verifies heap invariants while paused at a safepoint.
    pub fn verifyHeap(self: *const Debugger) heap.Heap.VerifyError!void {
        return self.vm.rt.heap.verify();
    }

    /// Triggers an immediate minor GC while paused at a safepoint, ensuring the VM's roots
    /// are registered before collection. Optionally runs `Heap.verifyCollected()` afterwards.
    pub fn triggerMinorGc(self: *Debugger, verify_after: bool) heap.Heap.VerifyError!GcReport {
        return self.runManualGc(.minor, verify_after);
    }

    /// Triggers an immediate major GC while paused at a safepoint, ensuring the VM's roots
    /// are registered before collection. Optionally runs `Heap.verifyCollected()` afterwards.
    pub fn triggerMajorGc(self: *Debugger, verify_after: bool) heap.Heap.VerifyError!GcReport {
        return self.runManualGc(.major, verify_after);
    }

    fn runManualGc(self: *Debugger, kind: GcKind, verify_after: bool) heap.Heap.VerifyError!GcReport {
        const h = &self.vm.rt.heap;
        const stats_before = inspector.inspectHeap(h);

        // Ensure the VM's live stacks, frames, and Proto constants are rooted (Vm.step()
        // registers `engine_roots` lazily on its first collection, so a freshly initialized
        // or paused VM may not have set it yet).
        const prev_roots = self.vm.rt.engine_roots;
        if (!self.vm.nested) {
            self.vm.rt.engine_roots = self.vm.roots();
        }
        defer if (!self.vm.nested) {
            if (prev_roots) |pr| {
                if (pr.ctx != @as(*anyopaque, self.vm)) self.vm.rt.engine_roots = pr;
            }
        };

        switch (kind) {
            .minor => {
                // Suppress major escalation so an explicit minor GC stays minor even under
                // `-Dgc-stress` (where `verify_always` still remains active).
                const prev_major_req = h.major_requested;
                const prev_next_major = h.next_major;
                const prev_collect_always = h.collect_always;
                h.major_requested = false;
                h.next_major = std.math.maxInt(usize);
                h.collect_always = false;
                defer {
                    h.major_requested = prev_major_req;
                    h.next_major = prev_next_major;
                    h.collect_always = prev_collect_always;
                }
                self.vm.rt.collect();
            },
            .major => {
                h.major_requested = true;
                self.vm.rt.collect();
            },
        }

        if (verify_after) {
            try h.verifyCollected();
        }

        const stats_after = inspector.inspectHeap(h);
        return .{
            .kind = kind,
            .bytes_before = stats_before.total_bytes,
            .bytes_after = stats_after.total_bytes,
            .freed_bytes = stats_before.total_bytes -| stats_after.total_bytes,
            .live_objects_before = stats_before.live_objects,
            .live_objects_after = stats_after.live_objects,
            .verified = verify_after,
        };
    }
};

fn decodeSlot(proto: *const Proto, index: u32, slot: Slot) LocalSlot {
    const is_param = index >= proto.param_slot and index < proto.param_slot + proto.param_count;
    if (slot.isUninit()) {
        return .{ .index = index, .is_param = is_param, .is_captured = false, .value = null };
    }
    if (slot.isCell()) {
        return .{ .index = index, .is_param = is_param, .is_captured = true, .value = slot.asCell().value };
    }
    return .{ .index = index, .is_param = is_param, .is_captured = false, .value = slot.asValue() };
}

fn opcodeAt(proto: *const Proto, pc: u32) ?Op {
    if (pc >= proto.code.len) return null;
    const byte = proto.code[pc];
    if (byte >= Op.count) return null;
    return @fromBackingInt(@intCast(byte));
}

fn protoDisplayName(proto: *const Proto) []const u8 {
    if (proto.kind == .script) {
        return if (proto.is_module) "<module>" else "<script>";
    }
    if (proto.name.len > 0) return proto.name;
    if (proto.inferred_name.len > 0) return proto.inferred_name;
    return "<anonymous>";
}

fn findProtoByIdRec(p: *const Proto, target_id: u32, cur: *u32) ?*const Proto {
    if (cur.* == target_id) return p;
    cur.* += 1;
    for (p.functions) |*f| {
        if (findProtoByIdRec(f, target_id, cur)) |found| return found;
    }
    return null;
}

fn findProtoIdRec(p: *const Proto, target: *const Proto, cur: *u32) ?u32 {
    if (p == target) return cur.*;
    cur.* += 1;
    for (p.functions) |*f| {
        if (findProtoIdRec(f, target, cur)) |found| return found;
    }
    return null;
}

fn findProtoByNameRec(p: *const Proto, name: []const u8) ?*const Proto {
    if (p.kind == .function) {
        if (std.mem.eql(u8, p.name, name) or std.mem.eql(u8, p.inferred_name, name)) return p;
    }
    for (p.functions) |*f| {
        if (findProtoByNameRec(f, name)) |found| return found;
    }
    return null;
}

fn collectProtosRec(
    alloc: Allocator,
    p: *const Proto,
    cur: *u32,
    out: *std.ArrayList(ProtoInfo),
) Allocator.Error!void {
    const id = cur.*;
    cur.* += 1;
    try out.append(alloc, .{
        .id = id,
        .proto = p,
        .name = protoDisplayName(p),
        .is_script = p.kind == .script,
        .code_len = p.code.len,
        .param_count = p.param_count,
        .slot_count = p.slot_count,
    });
    for (p.functions) |*f| {
        try collectProtosRec(alloc, f, cur, out);
    }
}
