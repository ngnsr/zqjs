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
- Done means `zig build test` passes. Never weaken, delete or skip an existing test to get there.
- Stay inside the files the task names. No new dependencies, no drive-by refactors.

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
