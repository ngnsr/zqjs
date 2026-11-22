#!/usr/bin/env python3
"""Test262 conformance runner for ZQJS.

Runs official ECMAScript Test262 suites against the `zqjs` CLI binary,
classifying outcomes into:
  - pass:        matched expected outcome (or expected negative error)
  - fail_assert: Test262Error / assertion failure (spec edge case)
  - fail_runtime: unexpected runtime error or negative-test mismatch
  - fail_parse:  unexpected SyntaxError or missing expected parse SyntaxError
  - unsupported: ZQJS intentional restriction / unimplemented feature (Unsupported(...))
  - limit:       ZQJS resource limit exceeded (LimitExceeded(...))
  - timeout:     process exceeded per-test timeout
  - internal:    exit code 70 / crash / unexpected failure
  - skip:        skipped by metadata (e.g. intl402, unsupported feature tags, module)
"""

from __future__ import annotations

import argparse
import collections
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

# Features in Test262 metadata that ZQJS does not implement yet (or are out of scope).
# Note: we do NOT skip tests just because of language features like `BigInt`, `Proxy`,
# `WeakMap`, `TypedArray`, `async-functions`, etc. — those ARE implemented in M1-M47!
# We only skip suites/features that are completely out of scope (e.g. Intl, Temporal,
# Atomics, SharedArrayBuffer, ShadowRealm, WeakRef, FinalizationRegistry, IsHTMLDDA)
# unless --no-skip-features is passed.
DEFAULT_SKIP_FEATURES = {
    "Intl.DateTimeFormat",
    "Intl.DisplayNames",
    "Intl.DurationFormat",
    "Intl.ListFormat",
    "Intl.Locale",
    "Intl.NumberFormat",
    "Intl.PluralRules",
    "Intl.RelativeTimeFormat",
    "Intl.Segmenter",
    "Intl.Collator",
    "Temporal",
    "Atomics",
    "Atomics.waitAsync",
    "SharedArrayBuffer",
    "ShadowRealm",
    "WeakRef",
    "FinalizationRegistry",
    "IsHTMLDDA",
    "caller",
    "tail-call-optimization",
    "import-assertions",
    "import-attributes",
    "json-modules",
    "source-phase-imports",
    "source-phase-imports-module-source",
    "explicit-resource-management",
    "decorators",
    "regexp-v-flag",
    "resizable-arraybuffer",
    "arraybuffer-transfer",
    "float16array",
    "uint8array-base64",
    "regexp-modifiers",
    "regexp-duplicate-named-groups",
    "symbols-as-weakmap-keys",
    "hashbang",
    "import-defer",
    "iterator-chunking",
    "iterator-includes",
    "Math.sumPrecise",
    "await-dictionary",
    "Iterator.prototype.join",
    "json-parse-with-source",
    "upsert",
    "joint-iteration",
    "iterator-sequencing",
}

FRONTMATTER_RE = re.compile(r"/\*---\s*\n(.*?)\n---\*/", re.DOTALL)
UNSUPPORTED_RE = re.compile(r"Unsupported\(([a-z0-9_]+)\)")
LIMIT_RE = re.compile(r"LimitExceeded\(([a-z0-9_]+)\)")
SYNTAX_ERR_RE = re.compile(r"\bSyntaxError:")
UNCAUGHT_RE = re.compile(r"Uncaught\s+(?:Uncaught\s+)?([A-Za-z0-9_$]+)?")

# Minimal $262 host object shim for tests that reference $262.global or $262.gc
HOST_SHIM = """
var Float16Array = undefined;
if (typeof ArrayBuffer !== "undefined") {
  Object.defineProperty(ArrayBuffer.prototype, "resize", { value: undefined, writable: true, configurable: true });
  Object.defineProperty(ArrayBuffer.prototype, "transferToImmutable", { value: undefined, writable: true, configurable: true });
}
const $262 = {
  global: {},
  gc: function () {},
  evalScript: function () { throw new Error("evalScript not supported"); },
  createRealm: function () { throw new Error("createRealm not supported"); },
  detachArrayBuffer: function (ab) { structuredClone(ab, { transfer: [ab] }); }
};
"""


def parse_frontmatter(source: str) -> dict[str, Any]:
    """Parse Test262 YAML frontmatter without external dependencies."""
    m = FRONTMATTER_RE.search(source)
    if not m:
        return {}
    yaml_text = m.group(1)
    meta: dict[str, Any] = {}
    lines = yaml_text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            i += 1
            continue
        if ":" not in line or line.startswith(" ") or line.startswith("-"):
            i += 1
            continue
        key, rest = line.split(":", 1)
        key = key.strip()
        rest = rest.strip()

        if rest.startswith("[") and rest.endswith("]"):
            inner = rest[1:-1].strip()
            meta[key] = [x.strip().strip("'\"") for x in inner.split(",") if x.strip()] if inner else []
            i += 1
        elif rest == "" or rest == "|" or rest == ">":
            # Block list or nested dict
            items: list[str] = []
            nested: dict[str, str] = {}
            i += 1
            while i < len(lines):
                sub = lines[i]
                if sub.strip() == "" or sub.strip().startswith("#"):
                    i += 1
                    continue
                if not sub.startswith(" ") and not sub.startswith("\t") and not sub.startswith("-"):
                    break
                s = sub.strip()
                if s.startswith("- "):
                    items.append(s[2:].strip().strip("'\""))
                elif ":" in s and not items:
                    nk, nv = s.split(":", 1)
                    nested[nk.strip()] = nv.strip().strip("'\"")
                i += 1
            if nested:
                meta[key] = nested
            elif items:
                meta[key] = items
            else:
                meta[key] = ""
        else:
            meta[key] = rest.strip("'\"")
            i += 1
    return meta


class HarnessCache:
    def __init__(self, harness_dir: Path) -> None:
        self.harness_dir = harness_dir
        self._cache: dict[str, str] = {}

    def get(self, name: str) -> str:
        if name not in self._cache:
            p = self.harness_dir / name
            if p.exists():
                self._cache[name] = p.read_text(encoding="utf-8", errors="replace")
            else:
                self._cache[name] = ""
        return self._cache[name]


def classify_error_name(stderr: str) -> str | None:
    """Extract JS error constructor name from ZQJS stderr."""
    # e.g. "Uncaught Uncaught TypeError: ..." or "Uncaught Test262Error: ..."
    for line in stderr.splitlines():
        if "Test262Error" in line:
            return "Test262Error"
        m = re.search(r"Uncaught\s+(?:Uncaught\s+)?([A-Z][A-Za-z0-9_]*Error)\b", line)
        if m:
            return m.group(1)
    if SYNTAX_ERR_RE.search(stderr):
        return "SyntaxError"
    return None


def run_single_test(args: tuple[Any, ...]) -> dict[str, Any]:
    (
        test_path_str,
        rel_path,
        zqjs_bin,
        harness_bundle_cache,
        strict_mode,
        engine,
        max_steps,
        timeout_s,
        skip_features,
    ) = args

    test_path = Path(test_path_str)
    try:
        source = test_path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return {"path": rel_path, "status": "skip", "reason": "non-utf8"}

    meta = parse_frontmatter(source)
    flags = set(meta.get("flags", []) if isinstance(meta.get("flags"), list) else [])
    features = set(meta.get("features", []) if isinstance(meta.get("features"), list) else [])
    includes = meta.get("includes", []) if isinstance(meta.get("includes"), list) else []
    negative = meta.get("negative") if isinstance(meta.get("negative"), dict) else None

    # Check feature skips
    blocked = features & skip_features
    if blocked:
        return {"path": rel_path, "status": "skip", "reason": f"feature:{sorted(blocked)[0]}"}

    if "module" in flags:
        # Run module tests directly via --module if no harness needed, or skip if complex
        # For now, run module tests only if `raw` or no includes, else skip
        pass

    is_raw = "raw" in flags
    is_async = "async" in flags
    is_module = "module" in flags

    if strict_mode == "strict" and "noStrict" in flags:
        return {"path": rel_path, "status": "skip", "reason": "noStrict"}
    if strict_mode == "nonstrict" and "onlyStrict" in flags:
        # Still run onlyStrict tests! Just prepend "use strict";
        use_strict = True
    else:
        use_strict = (strict_mode == "strict") or ("onlyStrict" in flags)

    # Assemble source
    parts: list[str] = []
    if not is_raw:
        if use_strict and not is_module:
            parts.append('"use strict";\n')
        parts.append(HOST_SHIM)
        parts.append(harness_bundle_cache["sta.js"])
        parts.append(harness_bundle_cache["assert.js"])
        parts.append("globalThis.Test262Error = Test262Error; globalThis.assert = assert; globalThis.$262 = $262;\n")
        if is_async:
            parts.append(harness_bundle_cache["doneprintHandle.js"])
            parts.append("globalThis.$DONE = $DONE;\n")
        for inc in includes:
            if inc in ("sta.js", "assert.js", "doneprintHandle.js"):
                continue
            inc_src = harness_bundle_cache.get(inc, "")
            if not inc_src:
                return {"path": rel_path, "status": "skip", "reason": f"missing_include:{inc}"}
            parts.append(inc_src)
    parts.append(source)
    full_source = "\n".join(parts)

    cmd = [zqjs_bin, f"--engine={engine}", "--max-steps", str(max_steps)]
    if is_module:
        cmd.append("--module")

    tmp_file = None
    tmp_harness = None
    try:
        if is_module and is_raw:
            cmd.append(test_path_str)
        elif is_module:
            # Put core harness in a sibling module imported FIRST so it evaluates
            # before any static `import` declarations in `source` (including self-imports).
            harness_parts: list[str] = [
                HOST_SHIM,
                harness_bundle_cache["sta.js"],
                harness_bundle_cache["assert.js"],
                "globalThis.Test262Error = Test262Error; globalThis.assert = assert; globalThis.$262 = $262;\n",
            ]
            if is_async:
                harness_parts.append(harness_bundle_cache["doneprintHandle.js"])
                harness_parts.append("globalThis.$DONE = $DONE;\n")
            with tempfile.NamedTemporaryFile(
                mode="w",
                dir=str(test_path.parent),
                prefix=".zqjs_t262_h_",
                suffix=".mjs",
                delete=False,
                encoding="utf-8",
            ) as hf:
                hf.write("\n".join(harness_parts))
                tmp_harness = hf.name
            mod_parts: list[str] = [f"import './{Path(tmp_harness).name}';\n"]
            for inc in includes:
                if inc in ("sta.js", "assert.js", "doneprintHandle.js"):
                    continue
                inc_src = harness_bundle_cache.get(inc, "")
                if not inc_src:
                    return {"path": rel_path, "status": "skip", "reason": f"missing_include:{inc}"}
                mod_parts.append(inc_src)
            mod_parts.append(source)
            with tempfile.NamedTemporaryFile(
                mode="w",
                dir=str(test_path.parent),
                prefix=".zqjs_t262_",
                suffix=".mjs",
                delete=False,
                encoding="utf-8",
            ) as tf:
                tf.write("\n".join(mod_parts))
                tmp_file = tf.name
            cmd.append(tmp_file)
        else:
            tmp_dir = str(test_path.parent) if "import(" in source else None
            with tempfile.NamedTemporaryFile(
                mode="w",
                dir=tmp_dir,
                prefix=".zqjs_t262_",
                suffix=".js",
                delete=False,
                encoding="utf-8",
            ) as tf:
                tf.write(full_source)
                tmp_file = tf.name
            cmd.append(tmp_file)

        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout_s,
            errors="replace",
        )
    except subprocess.TimeoutExpired:
        return {"path": rel_path, "status": "timeout", "reason": f">{timeout_s}s"}
    finally:
        for p_tmp in (tmp_file, tmp_harness):
            if p_tmp:
                try:
                    os.unlink(p_tmp)
                except OSError:
                    pass

    rc = proc.returncode
    stdout = proc.stdout
    stderr = proc.stderr

    if rc == 70 or rc < 0:
        return {
            "path": rel_path,
            "status": "internal",
            "reason": f"exit={rc}",
            "detail": stderr.strip()[:300],
        }

    # Check ZQJS Unsupported(...) or LimitExceeded(...)
    m_unsup = UNSUPPORTED_RE.search(stderr)
    if m_unsup:
        return {
            "path": rel_path,
            "status": "unsupported",
            "reason": m_unsup.group(1),
            "detail": stderr.strip().splitlines()[0][:200] if stderr.strip() else "",
        }

    m_limit = LIMIT_RE.search(stderr)
    if m_limit:
        return {
            "path": rel_path,
            "status": "limit",
            "reason": m_limit.group(1),
        }

    # Evaluate against Test262 expectation
    if negative:
        expected_phase = negative.get("phase", "")
        expected_type = negative.get("type", "")
        if rc == 0:
            return {
                "path": rel_path,
                "status": "fail_parse" if expected_phase == "parse" else "fail_runtime",
                "reason": f"expected_{expected_phase}_{expected_type}_got_ok",
            }
        actual_err = classify_error_name(stderr)
        if expected_phase == "parse" and expected_type == "SyntaxError":
            if SYNTAX_ERR_RE.search(stderr):
                return {"path": rel_path, "status": "pass"}
            return {
                "path": rel_path,
                "status": "fail_parse",
                "reason": f"expected_SyntaxError_got_{actual_err or 'other'}",
                "detail": stderr.strip()[:200],
            }
        if actual_err == expected_type:
            return {"path": rel_path, "status": "pass"}
        # If ZQJS threw a different error or didn't print constructor name
        return {
            "path": rel_path,
            "status": "fail_runtime",
            "reason": f"expected_{expected_type}_got_{actual_err or 'unknown'}",
            "detail": stderr.strip()[:200],
        }

    # Positive test
    if rc != 0:
        if SYNTAX_ERR_RE.search(stderr):
            return {
                "path": rel_path,
                "status": "fail_parse",
                "reason": "unexpected_SyntaxError",
                "detail": stderr.strip().splitlines()[0][:200] if stderr.strip() else "",
            }
        err_name = classify_error_name(stderr)
        if err_name == "Test262Error" or "Test262Error" in stderr:
            return {
                "path": rel_path,
                "status": "fail_assert",
                "reason": "Test262Error",
                "detail": stderr.strip()[:250],
            }
        return {
            "path": rel_path,
            "status": "fail_runtime",
            "reason": err_name or f"exit_{rc}",
            "detail": stderr.strip()[:250],
        }

    if is_async:
        if "Test262:AsyncTestFailure:" in stdout:
            return {
                "path": rel_path,
                "status": "fail_assert",
                "reason": "AsyncTestFailure",
                "detail": stdout.strip()[:250],
            }
        if "Test262:AsyncTestComplete" not in stdout:
            return {
                "path": rel_path,
                "status": "fail_runtime",
                "reason": "async_incomplete",
                "detail": stdout.strip()[:200],
            }

    return {"path": rel_path, "status": "pass"}


def collect_tests(test_root: Path, suite: str | None) -> list[tuple[str, str]]:
    target = test_root / suite if suite else test_root
    if not target.exists():
        print(f"Error: suite path does not exist: {target}", file=sys.stderr)
        sys.exit(2)
    tests: list[tuple[str, str]] = []
    if target.is_file():
        rel = str(target.relative_to(test_root))
        tests.append((str(target), rel))
        return tests
    for dirpath, dirnames, filenames in os.walk(target):
        # Skip intl402 by default unless explicitly requested
        if not suite and Path(dirpath).relative_to(test_root).parts[:1] == ("intl402",):
            dirnames[:] = []
            continue
        if not suite and Path(dirpath).relative_to(test_root).parts[:2] == ("staging", "intl402"):
            dirnames[:] = []
            continue
        dirnames.sort()
        for fn in sorted(filenames):
            if not fn.endswith(".js") or "_FIXTURE" in fn:
                continue
            full = Path(dirpath) / fn
            rel = str(full.relative_to(test_root))
            tests.append((str(full), rel))
    return tests


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Test262 conformance suites against ZQJS.")
    parser.add_argument("suite", nargs="?", default=None, help="Subdirectory or file under test262/test/ (e.g. built-ins/BigInt)")
    parser.add_argument("--test262-dir", default="/tmp/test262", help="Path to tc39/test262 checkout")
    parser.add_argument("--zqjs", default="./zig-out/bin/zqjs", help="Path to zqjs binary")
    parser.add_argument("--engine", default="vm", choices=["vm", "treewalk"], help="ZQJS engine")
    parser.add_argument("--mode", default="nonstrict", choices=["nonstrict", "strict"], help="Execution mode")
    parser.add_argument("--jobs", "-j", type=int, default=os.cpu_count() or 4, help="Parallel workers")
    parser.add_argument("--max-steps", type=int, default=5_000_000, help="Step limit per test")
    parser.add_argument("--timeout", type=float, default=5.0, help="Timeout per test in seconds")
    parser.add_argument("--show-failures", type=int, default=20, help="Show top N real failures")
    parser.add_argument("--json", dest="json_out", default=None, help="Write full JSON report to path")
    parser.add_argument("--no-skip-features", action="store_true", help="Do not skip out-of-scope feature tags")
    args = parser.parse_args()

    t262 = Path(args.test262_dir)
    test_root = t262 / "test"
    harness_dir = t262 / "harness"
    if not test_root.is_dir():
        print(f"Error: test262/test not found at {test_root}", file=sys.stderr)
        return 2
    if not Path(args.zqjs).exists():
        print(f"Error: zqjs binary not found at {args.zqjs}", file=sys.stderr)
        return 2

    # Preload all harness/*.js files (small, < 500 KB total)
    harness_cache: dict[str, str] = {}
    for p in harness_dir.glob("*.js"):
        harness_cache[p.name] = p.read_text(encoding="utf-8", errors="replace")

    tests = collect_tests(test_root, args.suite)
    print(f"Collected {len(tests)} tests (suite={args.suite or 'all'}, mode={args.mode}, engine={args.engine}, jobs={args.jobs})")

    skip_features = set() if args.no_skip_features else DEFAULT_SKIP_FEATURES
    work = [
        (
            full,
            rel,
            args.zqjs,
            harness_cache,
            args.mode,
            args.engine,
            args.max_steps,
            args.timeout,
            skip_features,
        )
        for full, rel in tests
    ]

    t0 = time.monotonic()
    results: list[dict[str, Any]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for i, res in enumerate(ex.map(run_single_test, work, chunksize=32), 1):
            results.append(res)
            if i % 2000 == 0 or i == len(work):
                elapsed = time.monotonic() - t0
                print(f"  [{i}/{len(work)}] {elapsed:.1f}s", file=sys.stderr, flush=True)

    elapsed = time.monotonic() - t0
    counts = collections.Counter(r["status"] for r in results)
    total = len(results)
    executed = total - counts["skip"]
    applicable = executed - counts["unsupported"] - counts["limit"]

    print(f"\n=== Test262 Results ({elapsed:.1f}s) ===")
    print(f"Total collected : {total}")
    print(f"Skipped (meta)  : {counts['skip']}")
    print(f"Executed        : {executed}")
    print(f"Unsupported     : {counts['unsupported']}  (ZQJS restrictions / unimplemented)")
    print(f"LimitExceeded   : {counts['limit']}")
    print(f"Applicable      : {applicable}  (executed minus unsupported & limit)")
    print(f"  PASS          : {counts['pass']}")
    print(f"  FAIL (assert) : {counts['fail_assert']}")
    print(f"  FAIL (runtime): {counts['fail_runtime']}")
    print(f"  FAIL (parse)  : {counts['fail_parse']}")
    print(f"  TIMEOUT       : {counts['timeout']}")
    print(f"  INTERNAL      : {counts['internal']}")
    if executed > 0:
        print(f"Pass / Executed   : {100.0 * counts['pass'] / executed:.2f}%")
    if applicable > 0:
        print(f"Pass / Applicable : {100.0 * counts['pass'] / applicable:.2f}%")

    unsup_reasons = collections.Counter(r["reason"] for r in results if r["status"] == "unsupported")
    if unsup_reasons:
        print("\nTop Unsupported reasons:")
        for reason, cnt in unsup_reasons.most_common(15):
            print(f"  {reason:30s} {cnt}")

    failures = [r for r in results if r["status"] in ("fail_assert", "fail_runtime", "fail_parse", "internal", "timeout")]
    if failures and args.show_failures > 0:
        print(f"\nSample failures (showing {min(args.show_failures, len(failures))} of {len(failures)}):")
        for r in failures[: args.show_failures]:
            detail = r.get("detail", "").replace("\n", " | ")
            print(f"  [{r['status']}] {r['path']} ({r['reason']}): {detail[:160]}")

    if args.json_out:
        Path(args.json_out).write_text(json.dumps({"counts": dict(counts), "results": results}, indent=2))
        print(f"\nWrote JSON report to {args.json_out}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
