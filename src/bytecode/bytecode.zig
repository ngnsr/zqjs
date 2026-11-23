//! The bytecode format: instruction set, encoding and the compiled script (`Proto`).
//! Shared by the compiler, the verifier, the disassembler and (M5) the VM, so the
//! format is defined exactly once: `Op.info()` is the single table of operands and
//! stack effects.
//!
//! Encoding
//! --------
//! A byte stream. Each instruction is a 1-byte opcode followed by its operands, each a
//! little-endian u32. u32 does not make limits unnecessary: code size and pool sizes
//! are bounded by `Limits.max_code_bytes` / `max_constants`, enforced by the compiler
//! and checked again by the verifier (DESIGN_DECISIONS D32).
//!
//! Operand kinds
//!   slot      index into the frame's local slots (< Proto.slot_count)
//!   const     index into Proto.consts
//!   name      index into Proto.names (variable names, for globals and error messages)
//!   target    absolute byte offset of the jump destination (an instruction start)
//!   argc      number of call arguments
//!   function  index into Proto.functions (the nested functions)
//!   capture   index into the running closure's captures (< Proto.captures.len)
//!
//! Slots (M6, DESIGN_DECISIONS D36). A slot holds either a value (`null` = TDZ) or, for
//! a binding an inner function captures, a heap Cell holding the value. The compiler
//! uses the *_local instructions for the first kind and the *_cell ones for the second;
//! the VM checks the slot's kind on every access (a mismatch is a bug, not JS).
//!
//! Stack discipline: every statement leaves the operand stack as it found it (empty),
//! every expression pushes exactly one value. `max_stack` is the deepest the stack
//! gets; the M5 VM reserves it once on entry and pushes without bounds checks
//! (DESIGN_DECISIONS D12), which is only sound because the verifier checks it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../runtime/value.zig").Value;
const heap = @import("../runtime/heap.zig");

pub const Operand = enum { slot, @"const", name, target, argc, function, capture, repl };

pub const Op = enum(u8) {
    // ---- constants: push one value
    push_undefined,
    push_null,
    push_true,
    push_false,
    /// Push consts[k] (a number or a string).
    push_const,

    // ---- locals. `name` is only used in error messages.
    /// Push slot s; ReferenceError if it is in the TDZ.
    get_local,
    /// Store the top of the stack into slot s and *keep* it (the value of an assignment
    /// expression); ReferenceError if s is in the TDZ.
    set_local,
    /// Store the top of the stack into slot s and pop it (M52 superinstruction).
    set_local_pop,
    /// Increment/decrement a non-captured mutable local in place (M52 superinstruction).
    inc_local,
    dec_local,
    /// Pop into slot s: initialises a declaration, so no TDZ or const check.
    init_local,
    /// Put slot s back into the TDZ: emitted on entering a block, so a re-entered loop
    /// body doesn't see the previous iteration's values.
    clear_local,
    /// A write to a `const` binding (known at compile time). Throws: ReferenceError if
    /// s is in the TDZ, TypeError otherwise. The compiler places it exactly where the
    /// write would happen, so the value and its side effects come first, as in the
    /// tree-walker. Never falls through at run time, but the verifier models it as
    /// stack-neutral fallthrough, which is the conservative choice.
    assign_const,

    /// Push the global `name`; ReferenceError if there is none.
    get_global,
    /// Push the global `name`, or `undefined` if there is none (for `typeof undeclared`).
    get_global_or_undefined,
    /// Write top-of-stack to global `name` (strict ReferenceError or sloppy globalThis write), keeping value.
    set_global,

    // ---- cells: slots holding captured bindings (same checks as the *_local forms)
    /// Put a fresh cell (in the TDZ) into slot s: emitted on scope entry, so every
    /// *execution* of a scope gets new captured bindings.
    new_cell,
    /// Move slot s's value (a parameter) into a fresh cell in slot s.
    box_local,
    /// Replace slot s's cell by a fresh one holding the same value: the per-iteration
    /// copy of a captured `for (let …)` binding (CreatePerIterationEnvironment).
    fresh_cell,
    get_cell,
    set_cell,
    init_cell,
    assign_const_cell,

    // ---- captures: cells of the running closure (bindings of enclosing functions)
    get_capture,
    set_capture,
    assign_const_capture,

    // ---- REPL persistent top-level bindings (D71)
    get_repl,
    set_repl,
    init_repl,
    assign_const_repl,
    /// Pop top of stack into `rt.repl_result`.
    save_repl_result,

    // ---- functions
    /// Push a new closure of functions[f], capturing as its `captures` describe: from
    /// this frame's slots (which must hold cells) or this closure's own captures.
    make_closure,
    /// Push the running closure (a named function expression's own name).
    push_callee,

    // ---- stack
    pop,
    dup,
    /// [a, b] → [a, b, a, b] (a member's base and key, for `o[k] op= v`).
    dup2,
    /// [x, y, top] → [top, x, y]: move the top below the next two (postfix `o.p++`).
    rot3,
    /// [x, y, z, top] → [top, x, y, z]: below the next three (postfix `o[k]++`).
    rot4,

    // ---- objects (M7, runtime/object.zig). Keys on the stack are converted by the
    // instruction that uses them (ToPropertyKey), which gives JS's order: for `o[k] = v`
    // after v is evaluated, for `o[k] op= v` at the read before it.
    /// Push a new ordinary object (prototype Object.prototype).
    new_object,
    /// [e0 … e(n-1)] → [array].
    new_array,
    /// Push a new RegExp object compiled from consts[k_pattern] and consts[k_flags] (M30, D61).
    new_regexp,
    /// Push the cached TemplateStringsArray for templates[idx] (tagged template literal).
    get_template_obj,
    /// [ctor, super_val] → [ctor, ctor_proto] (M33, D63).
    setup_class,
    /// [obj, method_closure] → [obj]: sets home_object = obj and defines non-enumerable obj[name].
    define_method,
    /// [obj, key, method_closure] → [obj]: sets home_object = obj and defines non-enumerable obj[key].
    define_elem_method,
    /// [obj, fn_closure] → [obj]: sets home_object = obj and defines accessor (flags: bit0=is_setter, bit1=enumerable).
    define_accessor,
    /// [obj, key, fn_closure] → [obj]: same with a computed/non-identifier key.
    define_elem_accessor,
    /// [target, fn_closure] → [target]: defines private method on target under current brand.
    define_private_method,
    /// [target, fn_closure] → [target]: defines private accessor (argc bit0=is_setter) on target under current brand.
    define_private_accessor,
    /// [target, key, val] → [target]: DefineOwnProperty(target, key, val) for public class fields.
    define_public_field,
    /// [target, val] → [target]: defines private field on target under current brand.
    define_private_field,
    /// [obj] → [val]: reads private member `#name` using current closure's brand.
    get_private,
    /// [obj, val] → [val]: writes private member `#name` using current closure's brand.
    set_private,
    /// [obj] → [bool]: `#name in obj` using current closure's brand.
    in_private,
    /// [ctor, key] → [ctor]: appends pre-evaluated computed field key to ctor.meta.field_keys.
    store_field_key,
    /// [ctor, fn_or_undef] → [ctor]: appends an InstanceInit entry (operands: name, packed kind+key_idx).
    add_instance_init,
    /// [ctor, static_fn] → [val]: invokes static_fn with this = ctor, home_object = ctor, brand = ctor.
    run_static_init,
    /// [ctor, fn_closure] → [fn_closure]: sets fn_closure.meta.brand = ctor.
    set_brand,
    /// [arg0 … arg(argc-1)] → [this]: `super(...args)` in derived constructor.
    super_call,
    /// [args_arr] → [this]: `super(...args)` with spread.
    super_call_spread,
    /// [] → [val]: `super.name`.
    super_get_prop,
    /// [key] → [val]: `super[key]`.
    super_get_elem,
    /// [val] → [val]: `super.name = val`.
    super_set_prop,
    /// [key, val] → [val]: `super[key] = val`.
    super_set_elem,
    /// [] → [val] (always throws ReferenceError for `delete super.x`).
    throw_delete_super,
    /// [obj, value] → [obj]: define obj.name (an object literal's `name: value`).
    define_prop,
    /// [obj, key, value] → [obj]: the same with a computed or literal key.
    define_elem,
    /// [base] → [base.name].
    get_prop,
    /// [] → [this.name] (fused `push_this` + `get_prop`).
    get_this_prop,
    /// [] → [this, this.name] (fused `push_this` + `dup` + `get_prop` for `this.m(...)`).
    get_this_method,
    /// [] → [locals[s].name] (fused `get_local` + `get_prop`, slot guaranteed initialized).
    get_local_prop,
    /// [base, key] → [base[key]].
    get_elem,
    /// [] → [locals[s0][locals[s1]]] (M54 superinstruction; both slots guaranteed initialized).
    get_elem_local,
    /// [base, value] → [value]: base.name = value.
    set_prop,
    /// [base, value] → []: base.name = value (discarded, M53).
    set_prop_pop,
    /// [base, key, value] → [value].
    set_elem,
    /// [base, key, value] → []: base[key] = value (discarded, M53).
    set_elem_pop,
    /// [base] → [delete base.name].
    delete_prop,
    /// [value] → [] (throws value as JS exception).
    throw,
    /// [base, key] → [delete base[key]].
    delete_elem,
    /// [key, object] → [key in object].
    in,
    /// [lhs, rhs] → [lhs instanceof rhs].
    instanceof,
    /// Push the frame's `this`; Unsupported(sloppy_this) if the call had no receiver.
    push_this,

    // ---- M26: destructuring, spread, rest, default parameters
    /// Push `args[i]` (or `undefined` if `i >= argc`).
    get_arg,
    /// Push a new array containing `args[i..argc]`.
    rest_array,
    /// Push a new unmapped `arguments` object containing `args[0..argc]`.
    make_arguments,
    /// [arr, val] → [arr]: append `val` to `arr`.
    array_push,
    /// [arr, iterable] → [arr]: append all elements of `iterable` to `arr`.
    array_spread,
    /// [obj, src] → [obj]: copy own enumerable string-keyed properties of `src` to `obj`.
    object_spread,
    /// [callee, args_arr] → [result].
    call_spread,
    /// [receiver, callee, args_arr] → [result].
    call_method_spread,
    /// [callee, args_arr] → [result].
    new_call_spread,
    /// [iter] → [array]: drain remaining elements of `iter` into a new array.
    iter_rest,
    /// [val] → [val]: throw TypeError if `val` is `null` or `undefined`.
    require_obj,
    /// [src, k0 … k(n-1)] → [rest_obj]: copy own enumerable properties of `src` except k0..k(n-1).
    object_rest,
    /// [] → [obj]: `import.meta` object for the enclosing module (M48, D78).
    get_import_meta,
    /// [specifier] → [promise]: dynamic `import(specifier)` (M48, D78).
    dynamic_import,

    // ---- operators (runtime/ops.zig): pop operands, push the result
    add,
    sub,
    mul,
    div,
    mod,
    /// [lhs] → [lhs op consts[k]] (M53 superinstructions).
    add_const,
    sub_const,
    mul_const,
    mod_const,
    /// [lhs] → [lhs op locals[s]] (M54 superinstructions; TDZ check with `name`).
    add_local,
    sub_local,
    mul_local,
    mod_local,
    pow,
    shl,
    shr,
    ushr,
    bit_and,
    bit_xor,
    bit_or,
    lt,
    le,
    gt,
    ge,
    strict_eq,
    strict_ne,
    loose_eq,
    loose_ne,
    neg,
    /// ToNumber: unary `+`, and the first step of `++`/`--`.
    to_number,
    to_numeric,
    to_string,
    not,
    bit_not,
    typeof,
    /// Number + 1 / number - 1. The operand is always the result of `to_number`.
    inc,
    dec,

    // ---- control
    jump,
    /// Pop; jump if falsy / truthy (ToBoolean).
    jump_if_false,
    jump_if_true,
    /// Pop rhs, lhs; jump if comparison is false (M52/M53 superinstructions).
    lt_jump_if_false,
    le_jump_if_false,
    gt_jump_if_false,
    ge_jump_if_false,
    strict_eq_jump_if_false,
    strict_ne_jump_if_false,
    /// Jump to target if (locals[slot] op consts[k]) is false (M57 superinstructions; slot guaranteed initialized).
    lt_local_const_jif,
    le_local_const_jif,
    strict_eq_local_const_jif,
    strict_ne_local_const_jif,
    /// [iterable] → [iterator]: obtain built-in iterator for `for...of` (M14.4).
    get_iter,
    /// [iterator] → [iterator, value, done_bool]: advance iterator (M14.4).
    iter_next,
    /// [iterator_or_undefined] → []: close iterator on normal/break/return abrupt exit.
    iter_close,
    /// [iterator_or_undefined] → []: close iterator on throw (suppressing return() errors).
    iter_close_throw,
    /// Stack: [callee, arg0 … arg(argc-1)] → [result]. The callee is evaluated first,
    /// then the arguments, and only then is it checked (TypeError if not callable,
    /// matching the tree-walker). A closure gets a new frame (D36) with no receiver; a
    /// native gets the arguments as a slice of the operand stack, valid only during the
    /// call (it cannot call back into JS, so the stack cannot move under it).
    call,
    /// Stack: [receiver, callee, arg0 … arg(argc-1)] → [result]: a method call `o.f(…)`;
    /// `this` is the receiver (D41). Otherwise exactly like `call`.
    call_method,
    /// Stack: [callee, arg0 … arg(argc-1)] → [result]: `new callee(args...)`.
    new_call,
    /// Pop the return value, leave the frame, and push the value in place of the
    /// callee and arguments in the caller. Function protos only; the stack must hold
    /// exactly the return value.
    @"return",
    /// End of the script. The stack must be empty. Script proto only.
    halt,
    /// [val] → [resumed_val]: suspend the async coroutine awaiting `val` (D56).
    await,
    /// Generator call (D67): suspend after the parameter prologue so the call can
    /// return the generator object. The first `next()` resumes past it.
    generator_start,
    /// [val] → [resumed_val, mode]: suspend the generator yielding `val` (D67); the resume
    /// pushes its value and mode (0 next, 1 throw, 2 return), which compiled code dispatches.
    /// Operand (argc kind): 1 for `yield*`'s raw inner result, returned to `next()` as is.
    yield,
    /// [iterator, received, mode] → [value, kind]: one round of `yield*` (D67): call the
    /// inner iterator's next/throw/return. kind 0: not done, value is the inner result to
    /// yield raw; 1: done, value is the `yield*` result; 2: done in return mode, return value.
    yield_star_step,
    /// [iterable] → [record]: GetIterator(iterable, async) for `for await`/async `yield*` (D68).
    get_async_iter,
    /// [record] → [result]: `for await` step: call `next`; the result is then awaited (D68).
    async_iter_next,
    /// [result] → [value, done]: check the awaited `next` result (TypeError if not an object).
    async_iter_result,
    /// [record_or_undefined] → [result, called]: AsyncIteratorClose up to its await; `called`
    /// false: nothing to await. The `_throw` form swallows errors (a throw completion).
    async_iter_close,
    async_iter_close_throw,
    /// [result] → []: AsyncIteratorClose after its await: TypeError if not an object.
    async_iter_close_check,
    /// [record, received, mode] → [kind, value]: one async `yield*` round up to its await (D68).
    async_yield_star_call,
    /// [kind, awaited] → [value, kind]: the rest of the round; kinds as `yield_star_step`'s.
    async_yield_star_result,
    /// [object] → [iter]: build a `for...in` iterator over own + inherited enumerable string keys (D69).
    for_in_init,
    /// [iter] → [key, done]: advance `for...in` iterator; pushes `(undefined, true)` when done (D69).
    for_in_next,

    pub const Info = struct {
        operands: []const Operand,
        /// Values popped; for `call`, add argc.
        pops: u32,
        pushes: u32,
    };

    /// Operands and stack effect. A table lookup: computed once, at compile time, from
    /// `infoOf` (the profile showed the switch itself on every instruction).
    pub fn info(op: Op) Info {
        return info_table[@backingInt(op)];
    }

    const info_table = blk: {
        var t: [count]Info = undefined;
        for (0..count) |i| t[i] = infoOf(@fromBackingInt(i));
        break :blk t;
    };

    const size_table = blk: {
        var t: [count]u8 = undefined;
        for (0..count) |i| t[i] = 1 + 4 * infoOf(@fromBackingInt(i)).operands.len;
        break :blk t;
    };

    fn infoOf(op: Op) Info {
        return switch (op) {
            .push_undefined, .push_null, .push_true, .push_false => .{ .operands = &.{}, .pops = 0, .pushes = 1 },
            .push_const => .{ .operands = &.{.@"const"}, .pops = 0, .pushes = 1 },
            .get_local => .{ .operands = &.{ .slot, .name }, .pops = 0, .pushes = 1 },
            .set_local, .assign_const => .{ .operands = &.{ .slot, .name }, .pops = 1, .pushes = 1 },
            .set_local_pop => .{ .operands = &.{ .slot, .name }, .pops = 1, .pushes = 0 },
            .inc_local, .dec_local => .{ .operands = &.{ .slot, .name }, .pops = 0, .pushes = 0 },
            .init_local => .{ .operands = &.{.slot}, .pops = 1, .pushes = 0 },
            .clear_local => .{ .operands = &.{.slot}, .pops = 0, .pushes = 0 },
            .get_global, .get_global_or_undefined => .{ .operands = &.{.name}, .pops = 0, .pushes = 1 },
            .set_global => .{ .operands = &.{.name}, .pops = 1, .pushes = 1 },
            .new_cell, .box_local, .fresh_cell => .{ .operands = &.{.slot}, .pops = 0, .pushes = 0 },
            .get_cell => .{ .operands = &.{ .slot, .name }, .pops = 0, .pushes = 1 },
            .set_cell, .assign_const_cell => .{ .operands = &.{ .slot, .name }, .pops = 1, .pushes = 1 },
            .init_cell => .{ .operands = &.{.slot}, .pops = 1, .pushes = 0 },
            .get_capture => .{ .operands = &.{ .capture, .name }, .pops = 0, .pushes = 1 },
            .set_capture, .assign_const_capture => .{ .operands = &.{ .capture, .name }, .pops = 1, .pushes = 1 },
            .get_repl => .{ .operands = &.{ .repl, .name }, .pops = 0, .pushes = 1 },
            .set_repl, .assign_const_repl => .{ .operands = &.{ .repl, .name }, .pops = 1, .pushes = 1 },
            .init_repl => .{ .operands = &.{.repl}, .pops = 1, .pushes = 0 },
            .save_repl_result => .{ .operands = &.{}, .pops = 1, .pushes = 0 },
            .make_closure => .{ .operands = &.{.function}, .pops = 0, .pushes = 1 },
            .push_callee => .{ .operands = &.{}, .pops = 0, .pushes = 1 },
            .@"return" => .{ .operands = &.{}, .pops = 1, .pushes = 0 },
            .pop => .{ .operands = &.{}, .pops = 1, .pushes = 0 },
            .dup => .{ .operands = &.{}, .pops = 1, .pushes = 2 },
            .dup2 => .{ .operands = &.{}, .pops = 2, .pushes = 4 },
            .rot3 => .{ .operands = &.{}, .pops = 3, .pushes = 3 },
            .rot4 => .{ .operands = &.{}, .pops = 4, .pushes = 4 },
            .new_object => .{ .operands = &.{}, .pops = 0, .pushes = 1 },
            .new_array => .{ .operands = &.{.argc}, .pops = 0, .pushes = 1 },
            .new_regexp => .{ .operands = &.{ .@"const", .@"const" }, .pops = 0, .pushes = 1 },
            .get_template_obj => .{ .operands = &.{.argc}, .pops = 0, .pushes = 1 },
            .setup_class => .{ .operands = &.{.argc}, .pops = 2, .pushes = 2 },
            .define_method => .{ .operands = &.{.name}, .pops = 2, .pushes = 1 },
            .define_elem_method => .{ .operands = &.{}, .pops = 3, .pushes = 1 },
            .define_accessor => .{ .operands = &.{ .name, .argc }, .pops = 2, .pushes = 1 },
            .define_elem_accessor => .{ .operands = &.{.argc}, .pops = 3, .pushes = 1 },
            .define_private_method => .{ .operands = &.{.name}, .pops = 2, .pushes = 1 },
            .define_private_accessor => .{ .operands = &.{ .name, .argc }, .pops = 2, .pushes = 1 },
            .define_public_field => .{ .operands = &.{}, .pops = 3, .pushes = 1 },
            .define_private_field => .{ .operands = &.{.name}, .pops = 2, .pushes = 1 },
            .get_private => .{ .operands = &.{.name}, .pops = 1, .pushes = 1 },
            .set_private => .{ .operands = &.{.name}, .pops = 2, .pushes = 1 },
            .in_private => .{ .operands = &.{.name}, .pops = 1, .pushes = 1 },
            .store_field_key => .{ .operands = &.{}, .pops = 2, .pushes = 1 },
            .add_instance_init => .{ .operands = &.{ .name, .argc }, .pops = 2, .pushes = 1 },
            .run_static_init => .{ .operands = &.{}, .pops = 2, .pushes = 1 },
            .set_brand => .{ .operands = &.{}, .pops = 2, .pushes = 1 },
            .super_call => .{ .operands = &.{.argc}, .pops = 0, .pushes = 1 },
            .super_call_spread => .{ .operands = &.{}, .pops = 1, .pushes = 1 },
            .super_get_prop => .{ .operands = &.{.name}, .pops = 0, .pushes = 1 },
            .super_get_elem => .{ .operands = &.{}, .pops = 1, .pushes = 1 },
            .super_set_prop => .{ .operands = &.{.name}, .pops = 1, .pushes = 1 },
            .super_set_elem => .{ .operands = &.{}, .pops = 2, .pushes = 1 },
            .throw_delete_super => .{ .operands = &.{}, .pops = 0, .pushes = 1 },
            .define_prop => .{ .operands = &.{.name}, .pops = 2, .pushes = 1 },
            .define_elem => .{ .operands = &.{}, .pops = 3, .pushes = 1 },
            .get_prop, .delete_prop => .{ .operands = &.{.name}, .pops = 1, .pushes = 1 },
            .get_this_prop => .{ .operands = &.{.name}, .pops = 0, .pushes = 1 },
            .get_this_method => .{ .operands = &.{.name}, .pops = 0, .pushes = 2 },
            .get_local_prop => .{ .operands = &.{ .slot, .name }, .pops = 0, .pushes = 1 },
            .get_elem, .delete_elem => .{ .operands = &.{}, .pops = 2, .pushes = 1 },
            .get_elem_local => .{ .operands = &.{ .slot, .slot }, .pops = 0, .pushes = 1 },
            .set_prop => .{ .operands = &.{.name}, .pops = 2, .pushes = 1 },
            .set_prop_pop => .{ .operands = &.{.name}, .pops = 2, .pushes = 0 },
            .set_elem => .{ .operands = &.{}, .pops = 3, .pushes = 1 },
            .set_elem_pop => .{ .operands = &.{}, .pops = 3, .pushes = 0 },
            .in, .instanceof => .{ .operands = &.{}, .pops = 2, .pushes = 1 },
            .push_this, .make_arguments => .{ .operands = &.{}, .pops = 0, .pushes = 1 },
            .get_arg, .rest_array => .{ .operands = &.{.argc}, .pops = 0, .pushes = 1 },
            .array_push, .array_spread, .object_spread => .{ .operands = &.{}, .pops = 2, .pushes = 1 },
            .call_spread, .new_call_spread => .{ .operands = &.{}, .pops = 2, .pushes = 1 },
            .call_method_spread => .{ .operands = &.{}, .pops = 3, .pushes = 1 },
            .iter_rest, .require_obj => .{ .operands = &.{}, .pops = 1, .pushes = 1 },
            .object_rest => .{ .operands = &.{.argc}, .pops = 1, .pushes = 1 },
            .call_method => .{ .operands = &.{.argc}, .pops = 2, .pushes = 1 },
            .add, .sub, .mul, .div, .mod, .pow, .shl, .shr, .ushr, .bit_and, .bit_xor, .bit_or, .lt, .le, .gt, .ge, .strict_eq, .strict_ne, .loose_eq, .loose_ne => .{ .operands = &.{}, .pops = 2, .pushes = 1 },
            .add_const, .sub_const, .mul_const, .mod_const => .{ .operands = &.{.@"const"}, .pops = 1, .pushes = 1 },
            .add_local, .sub_local, .mul_local, .mod_local => .{ .operands = &.{ .slot, .name }, .pops = 1, .pushes = 1 },
            .neg, .to_number, .to_numeric, .to_string, .not, .bit_not, .typeof, .inc, .dec => .{ .operands = &.{}, .pops = 1, .pushes = 1 },
            .jump => .{ .operands = &.{.target}, .pops = 0, .pushes = 0 },
            .jump_if_false, .jump_if_true => .{ .operands = &.{.target}, .pops = 1, .pushes = 0 },
            .lt_jump_if_false, .le_jump_if_false, .gt_jump_if_false, .ge_jump_if_false, .strict_eq_jump_if_false, .strict_ne_jump_if_false => .{ .operands = &.{.target}, .pops = 2, .pushes = 0 },
            .lt_local_const_jif, .le_local_const_jif, .strict_eq_local_const_jif, .strict_ne_local_const_jif => .{ .operands = &.{ .target, .slot, .@"const" }, .pops = 0, .pushes = 0 },
            .get_iter, .for_in_init => .{ .operands = &.{}, .pops = 1, .pushes = 1 },
            .iter_next, .for_in_next => .{ .operands = &.{}, .pops = 1, .pushes = 2 },
            .iter_close, .iter_close_throw => .{ .operands = &.{}, .pops = 1, .pushes = 0 },
            .call, .new_call => .{ .operands = &.{.argc}, .pops = 1, .pushes = 1 },
            .halt => .{ .operands = &.{}, .pops = 0, .pushes = 0 },
            .await => .{ .operands = &.{}, .pops = 1, .pushes = 1 },
            .generator_start => .{ .operands = &.{}, .pops = 0, .pushes = 0 },
            .yield => .{ .operands = &.{.argc}, .pops = 1, .pushes = 2 },
            .yield_star_step => .{ .operands = &.{}, .pops = 3, .pushes = 2 },
            .get_async_iter, .async_iter_next => .{ .operands = &.{}, .pops = 1, .pushes = 1 },
            .async_iter_result, .async_iter_close, .async_iter_close_throw => .{ .operands = &.{}, .pops = 1, .pushes = 2 },
            .async_iter_close_check => .{ .operands = &.{}, .pops = 1, .pushes = 0 },
            .async_yield_star_call => .{ .operands = &.{}, .pops = 3, .pushes = 2 },
            .async_yield_star_result => .{ .operands = &.{}, .pops = 2, .pushes = 2 },
            .throw => .{ .operands = &.{}, .pops = 1, .pushes = 0 },
            .get_import_meta => .{ .operands = &.{}, .pops = 0, .pushes = 1 },
            .dynamic_import => .{ .operands = &.{}, .pops = 1, .pushes = 1 },
        };
    }

    /// Values popped, given the instruction's argc operand (if it has one): `call`,
    /// `call_method` and `new_array` pop their arguments too.
    pub fn popsWith(op: Op, argc: u32) u64 {
        const extra: u64 = switch (op) {
            .call, .call_method, .new_call, .super_call, .new_array, .object_rest => argc,
            else => 0,
        };
        return op.info().pops + extra;
    }

    /// The opcode a byte encodes, or null. Opcodes are 0 … count-1 with no gaps
    /// (checked below), so this is one compare. (std.enums.fromInt searches every value:
    /// measured 3× slower in the VM's loop once M7 grew the instruction set.)
    pub fn decode(byte: u8) ?Op {
        return if (byte < count) @fromBackingInt(byte) else null;
    }

    pub const count = @typeInfo(Op).@"enum".field_names.len;

    comptime {
        for (@typeInfo(Op).@"enum".field_values, 0..) |v, i| std.debug.assert(v == i);
    }

    /// Encoded length in bytes.
    pub fn size(op: Op) u32 {
        return size_table[@backingInt(op)];
    }
};

/// Reads the u32 operand starting at `pos`. The caller guarantees it is in bounds
/// (the verifier checks this for every instruction).
pub fn readU32(code: []const u8, pos: usize) u32 {
    return std.mem.readInt(u32, code[pos..][0..4], .little);
}

/// A compiled script or function. The script's Proto is the root of a tree: each Proto
/// owns its nested functions' Protos (`functions`).
///
/// Ownership: `code`, `consts` (the slice), `names` and every name, `captures`,
/// `functions` and `name` are owned by the Proto and freed (recursively) by `deinit`
/// with the allocator given to the compiler. Closures point at their Proto, so a Proto
/// must outlive every *use* of its closures (in `runSource`: the run). String
/// constants are heap objects owned by the runtime heap the compiler was given: the
/// Proto must not outlive that heap. Without a GC (until M8) heap objects live until
/// `Heap.deinit`; with one, the Proto is what keeps them alive (it marks its constants,
/// DESIGN_DECISIONS D9). If compilation fails, the compiler frees the strings it made
/// (`Heap.rollback`), so a failed compile leaves the heap as it found it.
pub const Proto = struct {
    kind: enum { script, function } = .script,
    is_arrow: bool = false,
    /// Calls run as a coroutine (D56): async functions and, with `is_generator`, generators
    /// (D67), so every call path's coroutine check covers both.
    is_async: bool = false,
    is_generator: bool = false,
    /// An async generator (D68): `is_async` and `is_generator` are both set, and `await` is valid.
    is_async_generator: bool = false,
    is_method: bool = false,
    is_class_constructor: bool = false,
    is_strict: bool = false,
    has_super_ctor: bool = false,
    has_home_object: bool = false,
    length: u16 = 0,
    /// The function's name, for listings and traces ("" if anonymous or the script).
    name: []const u8 = "",
    /// Contextually inferred `.name` for anonymous functions/arrows/methods (D62).
    inferred_name: []const u8 = "",
    code: []const u8,
    /// Numbers and strings only.
    consts: []const Value,
    /// Variable names (source text, ASCII), copied out of the source.
    names: []const []const u8,
    /// Pre-interned weak atoms parallel to `names` (M10.4b); marked by `Vm.markProto`
    /// while the Proto is rooted, and swept by major GC once the Proto is gone.
    name_atoms: []const *heap.String = &.{},
    slot_count: u32,
    max_stack: u32,
    /// Parameters occupy slots param_slot … param_slot+param_count-1, filled by the call.
    param_count: u32 = 0,
    param_slot: u32 = 0,
    /// How `make_closure` fills a new closure's captures, in order (empty for the script).
    captures: []const Capture = &.{},
    functions: []Proto = &.{},
    /// Exception handlers ordered innermost-first (M11.2).
    handlers: []const ExceptionHandler = &.{},
    /// Tagged template call sites (M32b).
    templates: []const TemplateSite = &.{},
    /// Number of REPL / module top-level bindings referenced by this script/function (D71, D72).
    repl_count: u32 = 0,
    /// Borrowed from REPL Session or ModuleRecord for the lifetime of the chunk (D71, D72).
    repl_cells: []*heap.Cell = &.{},
    /// True when compiled from an ES Module (`this` at top-level is `undefined`, D72).
    is_module: bool = false,
    /// Borrowed `*ModuleRecord` for `import.meta` and relative dynamic `import()` (M48, D78).
    module_record: ?*anyopaque = null,

    pub const TemplateSite = struct {
        /// Indices into `consts` (`std.math.maxInt(u32)` means `undefined` for invalid escapes).
        cooked: []const u32,
        /// Indices into `consts` (always string constants).
        raw: []const u32,
    };

    pub const Capture = struct {
        from: enum { parent_slot, parent_capture },
        index: u32,
    };

    pub const ExceptionHandler = struct {
        try_start: u32,
        try_end: u32,
        catch_pc: u32,
        stack_depth: u32,
        has_binding: bool,
    };

    pub fn deinit(p: *Proto, gpa: Allocator) void {
        for (p.functions) |*f| f.deinit(gpa);
        gpa.free(p.functions);
        gpa.free(p.handlers);
        gpa.free(p.captures);
        gpa.free(p.name);
        if (p.inferred_name.len > 0) gpa.free(p.inferred_name);
        gpa.free(p.code);
        gpa.free(p.consts);
        for (p.names) |n| gpa.free(n);
        gpa.free(p.names);
        gpa.free(p.name_atoms);
        for (p.templates) |t| {
            gpa.free(t.cooked);
            gpa.free(t.raw);
        }
        gpa.free(p.templates);
        p.* = undefined;
    }
};

test "every opcode has a consistent size" {
    inline for (@typeInfo(Op).@"enum".field_values) |value| {
        const op: Op = @fromBackingInt(value);
        try std.testing.expect(op.size() == 1 or op.size() == 5 or op.size() == 9 or op.size() == 13);
    }
}
