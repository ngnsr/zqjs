#!/usr/bin/env python3
"""Reproducible ZQJS vs QuickJS CLI-to-CLI & ZQJS embedding benchmark runner."""

import hashlib
import math
import os
import platform
import shutil
import statistics
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
JS_DIR = ROOT / "bench" / "suite" / "js"
OUT_PATH = ROOT / "bench" / "suite" / "baseline-qjs.md"

WARMUPS = 2
RUNS = 11

# Explicit per-benchmark result comparison rules (no blanket tolerance).
BENCH_RULES = {
    "int_loop.js": "exact_int",
    "branch_dense.js": "exact_int",
    "float_math.js": "float_finite_exact",
    "fib.js": "exact_int",
    "call_chain.js": "exact_int",
    "closures.js": "exact_int",
    "scopes.js": "exact_int",
    "global_reads.js": "exact_int",
    "objects.js": "exact_int",
    "arrays.js": "exact_int",
    "strings.js": "exact_int",
}


def run_cmd(argv, capture=True):
    return subprocess.run(argv, cwd=ROOT, text=True, capture_output=capture, check=True)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def parse_result(stdout: str, name: str) -> str:
    lines = [ln.strip() for ln in stdout.strip().splitlines() if ln.strip()]
    for ln in reversed(lines):
        if ln.startswith("RESULT "):
            return ln[len("RESULT "):].strip()
    raise RuntimeError(f"{name}: missing 'RESULT ...' line in output: {stdout!r}")


def check_parity(rule: str, z_val: str, q_val: str, name: str) -> None:
    if rule == "exact_int":
        if int(z_val) != int(q_val):
            raise RuntimeError(f"{name} parity mismatch: zqjs={z_val!r} qjs={q_val!r}")
    elif rule == "float_finite_exact":
        zf = float(z_val)
        qf = float(q_val)
        if not (math.isfinite(zf) and math.isfinite(qf)):
            raise RuntimeError(f"{name} non-finite result: zqjs={z_val!r} qjs={q_val!r}")
        if (z_val.startswith("-0") != q_val.startswith("-0")) and zf == 0.0:
            raise RuntimeError(f"{name} -0 sign mismatch: zqjs={z_val!r} qjs={q_val!r}")
        if not math.isclose(zf, qf, rel_tol=1e-12, abs_tol=0.0):
            raise RuntimeError(f"{name} float mismatch: zqjs={z_val!r} qjs={q_val!r}")
    else:
        if z_val != q_val:
            raise RuntimeError(f"{name} parity mismatch: zqjs={z_val!r} qjs={q_val!r}")


def time_cli(exe: str, script: Path) -> float:
    t0 = time.perf_counter_ns()
    res = subprocess.run([exe, str(script)], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    dt = (time.perf_counter_ns() - t0) / 1e6
    if res.returncode != 0:
        raise RuntimeError(f"{exe} {script} failed ({res.returncode}): {res.stderr}")
    return dt


def measure_rss_mac(argv) -> int | None:
    if platform.system() != "Darwin":
        return None
    res = subprocess.run(["/usr/bin/time", "-l", *argv], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    for ln in res.stderr.splitlines():
        if "maximum resident set size" in ln:
            return int(ln.strip().split()[0])
    return None


def main() -> None:
    print("[bench] Building ReleaseFast CLI + bench-js + bench-c...")
    run_cmd(["zig", "build", "-Doptimize=ReleaseFast"], capture=False)
    zqjs_bin = str(ROOT / "zig-out" / "bin" / "zqjs")
    qjs_path = shutil.which("qjs")
    if not qjs_path:
        raise RuntimeError("qjs not found in PATH")
    node_path = shutil.which("node")

    qjs_ver = run_cmd([qjs_path, "--help"]).stdout.splitlines()[0].strip() if False else subprocess.run(
        [qjs_path, "--help"], capture_output=True, text=True
    ).stdout.splitlines()[0].strip()
    qjs_sha = sha256_file(Path(qjs_path))
    zig_ver = run_cmd(["zig", "version"]).stdout.strip()

    power_info = "unknown"
    if platform.system() == "Darwin":
        batt = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True).stdout.strip().splitlines()
        lpm = subprocess.run(["pmset", "-g"], capture_output=True, text=True).stdout
        lpm_line = next((ln.strip() for ln in lpm.splitlines() if "lowpowermode" in ln), "lowpowermode: ?")
        power_info = f"{batt[0] if batt else '?'} | {lpm_line}"

    scripts = sorted(JS_DIR.glob("*.js"))

    # 1. Correctness parity check
    print("[bench] Checking normalized result parity (zqjs vs qjs)...")
    parity_rows = []
    for s in scripts:
        rule = BENCH_RULES.get(s.name, "exact_int")
        z_out = parse_result(run_cmd([zqjs_bin, str(s)]).stdout, s.name)
        q_out = parse_result(run_cmd([qjs_path, str(s)]).stdout, s.name)
        check_parity(rule, z_out, q_out, s.name)
        n_out = "-"
        if node_path:
            nr = subprocess.run([node_path, "-e", f"const print = console.log;\n{s.read_text()}"], capture_output=True, text=True)
            if nr.returncode == 0:
                n_out = parse_result(nr.stdout, s.name)
        parity_rows.append((s.name, rule, z_out, q_out, n_out))

    # 2. Alternating CLI-to-CLI timings
    print("[bench] Running alternating CLI-to-CLI benchmarks...")
    cli_rows = []
    raw_samples = []
    for s in scripts:
        for _ in range(WARMUPS):
            time_cli(zqjs_bin, s)
            time_cli(qjs_path, s)

        z_times = []
        q_times = []
        order = []
        for i in range(RUNS):
            if i % 2 == 0:
                order.append("zqjs->qjs")
                z_times.append(time_cli(zqjs_bin, s))
                q_times.append(time_cli(qjs_path, s))
            else:
                order.append("qjs->zqjs")
                q_times.append(time_cli(qjs_path, s))
                z_times.append(time_cli(zqjs_bin, s))

        z_med = statistics.median(z_times)
        q_med = statistics.median(q_times)
        z_rss = measure_rss_mac([zqjs_bin, str(s)])
        q_rss = measure_rss_mac([qjs_path, str(s)])
        cli_rows.append((s.name, z_med, min(z_times), max(z_times), q_med, min(q_times), max(q_times), z_med / q_med, z_rss, q_rss))
        raw_samples.append((s.name, order, z_times, q_times))

    # 3. Split-phase ZQJS harness + GC workloads
    print("[bench] Running zig build bench-js -- --gc...")
    bench_js_out = run_cmd(["zig", "build", "bench-js", "--", "--gc"]).stdout.strip()

    # 4. ZQJS C-ABI embedding harness
    print("[bench] Running zig build bench-c...")
    bench_c_out = run_cmd(["zig", "build", "bench-c"]).stdout.strip()

    # Write baseline report
    lines = [
        "# ZQJS Performance Baseline",
        "",
        "## Environment & Pinning",
        f"- **Date (UTC):** {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}",
        f"- **Host:** {platform.system()} {platform.machine()} ({platform.platform()})",
        f"- **Power:** {power_info}",
        f"- **Zig:** `{zig_ver}` (`-Doptimize=ReleaseFast`, `smp_allocator`)",
        f"- **QuickJS CLI:** `{qjs_path}` — `{qjs_ver}` (SHA-256: `{qjs_sha}`)",
        f"- **Protocol:** {WARMUPS} warm-up + {RUNS} alternating measured runs per CLI benchmark; 30x3,600 runs for C frame loop",
        "",
        "## 1. Normalized Correctness Parity",
        "| Benchmark | Rule | ZQJS | QuickJS | Node (ref) |",
        "|---|---|---|---|---|",
    ]
    for name, rule, zv, qv, nv in parity_rows:
        lines.append(f"| `{name}` | `{rule}` | `{zv}` | `{qv}` | `{nv}` |")

    lines += [
        "",
        "## 2. CLI-to-CLI End-to-End Comparison (Startup + Parse + Compile + Run)",
        "| Benchmark | ZQJS med (ms) | ZQJS [min, max] | QuickJS med (ms) | QuickJS [min, max] | Ratio (`zqjs/qjs`) | ZQJS RSS (KiB) | QuickJS RSS (KiB) |",
        "|---|---:|---|---:|---|---:|---:|---:|",
    ]
    for name, zm, zlo, zhi, qm, qlo, qhi, ratio, zrss, qrss in cli_rows:
        z_kib = f"{zrss // 1024}" if zrss else "-"
        q_kib = f"{qrss // 1024}" if qrss else "-"
        lines.append(f"| `{name}` | {zm:.2f} | [{zlo:.2f}, {zhi:.2f}] | {qm:.2f} | [{qlo:.2f}, {qhi:.2f}] | **{ratio:.2f}x** | {z_kib} | {q_kib} |")

    lines += [
        "",
        "## 3. ZQJS Split-Phase & GC Benchmarks (`zig build bench-js -- --gc`)",
        "```text",
        bench_js_out,
        "```",
        "",
        "## 4. ZQJS C-ABI Embedding Benchmarks (`zig build bench-c`, separate from QuickJS)",
        "```text",
        bench_c_out,
        "```",
        "",
        "## 5. Individual CLI Sample Timings (ms, alternating order)",
    ]
    for name, order, zt, qt in raw_samples:
        z_str = ", ".join(f"{v:.2f}" for v in zt)
        q_str = ", ".join(f"{v:.2f}" for v in qt)
        lines.append(f"- **`{name}`** (`{order[0]}`, alternating): zqjs=[{z_str}] | qjs=[{q_str}]")

    OUT_PATH.write_text("\n".join(lines) + "\n")
    print(f"[bench] Wrote {OUT_PATH}")


if __name__ == "__main__":
    main()
