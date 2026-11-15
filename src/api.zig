//! ZQJS's public embedding API (M9.0; design in M9_0_PLAN.md, decisions D46-D49).
//!
//! This is the only module an embedder's build gets (`zqjs`). It is built on the internal
//! module (`zqjs_internal`, src/root.zig) and exposes none of it: the VM, the heap, bytecode
//! and the GC stay private, so changing them never breaks an embedder. Every public
//! declaration is pinned by tests/api_test.zig: a new one is a reviewed decision.
//!
//! P1: the resource limits. The runtime, programs and executions arrive in P2.

const internal = @import("zqjs_internal");

/// Resource limits of a runtime (DESIGN_DECISIONS D15): heap bytes, string length, call
/// depth, steps per execution…
pub const Limits = internal.Limits;
/// Which limit an operation hit.
pub const Limit = internal.Limit;
