# Agents

Rules for any coding agent working in this repo (opencode reads this file automatically),
plus how to hand work to opencode's free models.

## Rules for every agent
- Zig **0.17.1** exactly. You probably don't know its std API from memory: read the source in
  `/opt/homebrew/Cellar/zig/0.17.1/lib/zig/std` (`zig env` shows `lib_dir`) instead of guessing.
- Read `ARCHITECTURE.md` and the parts of `DESIGN_DECISIONS.md` that touch your change first.
  Never contradict a decision there; if a task seems to need that, stop and say so.
- Match the code around you: `std.ArrayList(T) = .empty` (unmanaged; allocator per call), the
  existing error sets, `limits.zig` for every bound, the same comment density (why, not what).
- Done means `zig build test` passes (on macOS, prefer `-Doptimize=ReleaseSafe` for full/stress runs). Never weaken, delete or skip an existing test to get there.
- Stay inside the files the task names. No new dependencies, no drive-by refactors.

## Fast Build & Test Discipline
On macOS arm64, Zig 0.17.1 compiles each artifact as a monolithic LLVM unit (~1 min Debug, ~3 min
ReleaseSafe, ~1 GB RAM per binary) with no incremental LLVM codegen. Full `zig build test`
compiles 5 binaries in parallel (~4.7 GB RAM). To iterate fast without thrashing memory:
- **Iterate with single-binary targets** (1 compile instead of 5):
  - `zig build test-diff`, `test-gc`, `test-vm`, `test-module`, `test-repl`, `test-syntax`, `test-unit`, `test-api`, or `test-fast` (umbrella `internal_tests`, 254 tests).
  - `zig build cli` (builds only `./zig-out/bin/zqjs`, skipping `libzqjs.a` — use before Test262 or REPL checks).
- **Use `Debug` for quick single-suite iteration** (`tests/support.zig` disables stack traces on `ProgramAllocator`, so non-stress suites run fast and compile ~3× faster than `ReleaseSafe`).
- **Save full `ReleaseSafe` + stress runs for final verification** before committing:
  - `zig fmt --check .`
  - `zig build check-goldens`
  - `zig build test -Doptimize=ReleaseSafe --summary all`
  - `zig build test -Dgc-stress -Dstack-stress -Doptimize=ReleaseSafe --summary all`
- **Avoid `-fincremental` on macOS arm64** (experimental with Mach-O / LLVM and can spike memory), and avoid launching overlapping full `zig build test` runs across multiple worktrees at the same time.

## Delegating to opencode
Use it for self-contained pieces with a fixed interface and tests written in advance:
a new opcode handler, one `runtime/ops.zig` operation, parser cases for one syntax form,
more tests and fixtures under `tests/`.

Keep for yourself (or a stronger model): compiler and VM design, `runtime/heap.zig` and the
GC, anything that changes or needs a new entry in `DESIGN_DECISIONS.md`.

Models (measured 2026-11-14 on a Zig 0.17 task, checked against a hidden test):
1. `opencode/glm-5.3-flash-free`: cleanest, most idiomatic code. Default.
2. `opencode/minimax-m3.1-flash-free`: fastest, careful with `errdefer`. Fallback.

Also passed: `deepseek-v4.1-flash-free`, `big-pickle` (4-6 min), `flint-40b-free` (11 min, slow).
Avoid: `longcat-2.5-free` (ended with code that doesn't compile), `mimo-v2.6-flash-free` (no file after 15 min).

Run it in a separate worktree, because `--auto` approves every command it wants to run:

```sh
git worktree add ../zqjs-oc -b oc/<task>
cd ../zqjs-oc
opencode run --standalone --auto -m opencode/glm-5.3-flash-free "<task>"
```

The prompt must state: the exact files to touch, the function signatures, the test that must
pass, and "run `zig build test` and iterate until it passes". Expect 4-6 minutes for a small task.

Then review the diff yourself before merging. Look for missed edge cases (allocation failure
mid-update, `-0`, limits), style drift, and tests that were changed instead of the code.
Don't put secrets in prompts: free models may keep what you send.
