#!/usr/bin/env python3
"""Rank the heaviest edges in -Dop-profile dumps (PERF_PLAN.md §5).

Build and collect one dump per workload (the profile goes to stderr at runtime teardown):

    zig build cli -Doptimize=ReleaseFast -Dop-profile
    ./zig-out/bin/zqjs bench/macro/physics_tick.js 2> /tmp/physics_tick.prof
    python3 tools/op_graph.py /tmp/*.prof

The report lists, per workload: instruction and native-call volume, property-cache miss
rates, the most executed opcodes; across workloads (each weighted equally): the heaviest
opcode -> next-opcode edges; and the busiest native calls and cache-miss sites. Counts, not
time: confirm a candidate's cost with a sampling profiler before optimising it.
Python 3 standard library only.
"""
import argparse
import collections
import os
import sys


def load(path):
    """The last profile in the file (one per runtime teardown) as counters."""
    ops, pairs, natives, misses = collections.Counter(), collections.Counter(), collections.Counter(), []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            fields = line.rstrip("\n").split("\t")
            tag = fields[0]
            if tag == "OPPROFILE":
                ops, pairs, natives, misses = collections.Counter(), collections.Counter(), collections.Counter(), []
            elif tag == "OP" and len(fields) == 3:
                ops[fields[1]] += int(fields[2])
            elif tag == "PAIR" and len(fields) == 4:
                pairs[(fields[1], fields[2])] += int(fields[3])
            elif tag == "NAT" and len(fields) == 3:
                natives[fields[1]] += int(fields[2])
            elif tag == "MISS" and len(fields) == 6:
                misses.append((fields[1], fields[2], int(fields[3]), fields[4], int(fields[5])))
    return ops, pairs, natives, misses


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("dumps", nargs="+", help="files holding a zqjs -Dop-profile dump (its stderr)")
    ap.add_argument("--top", type=int, default=15, help="rows per section (default 15)")
    args = ap.parse_args()

    data = {}
    for path in args.dumps:
        name = os.path.splitext(os.path.basename(path))[0]
        data[name] = load(path)
        if not data[name][0]:
            sys.exit(f"{path}: no -Dop-profile dump found (build with -Dop-profile, capture stderr)")
    names = list(data)
    width = max(len(n) for n in names)

    print("## Volume and property-cache misses")
    for n in names:
        ops, _, natives, misses = data[n]
        total = sum(ops.values())
        gets = sum(c for o, c in ops.items() if o.startswith("get_") and "prop" in o)
        sets = sum(c for o, c in ops.items() if o.startswith("set_") and "prop" in o)
        get_miss = sum(m[4] for m in misses if m[0] == "get")
        set_miss = sum(m[4] for m in misses if m[0] == "set")
        print(f"{n:{width}}  {total / 1e6:7.2f}M ops  {1000 * sum(natives.values()) / total:5.1f} native calls/1k ops  "
              f"get miss {100 * get_miss / max(gets, 1):4.1f}%  set miss {100 * set_miss / max(sets, 1):4.1f}%")

    print("\n## Most executed opcodes (share of instructions)")
    for n in names:
        ops = data[n][0]
        total = sum(ops.values())
        print(f"{n:{width}}  " + ", ".join(f"{o} {100 * c / total:.1f}%" for o, c in ops.most_common(8)))

    print("\n## Heaviest opcode -> opcode edges (mean share; per-workload % in brackets)")
    print(f"{'':>8}  {'from':>24}    {'to':<24} [{' '.join(names)}]")
    mean = collections.Counter()
    shares = {}
    for n in names:
        pairs = data[n][1]
        total = sum(pairs.values())
        shares[n] = {k: c / total for k, c in pairs.items()}
        for k, s in shares[n].items():
            mean[k] += s / len(names)
    for (a, b), s in mean.most_common(args.top):
        per = " ".join(f"{100 * shares[n].get((a, b), 0):.1f}" for n in names)
        print(f"  {100 * s:5.2f}%  {a:>24} -> {b:<24} [{per}]")

    print("\n## Native calls (per 1k instructions)")
    for n in names:
        ops, _, natives, _ = data[n]
        total = sum(ops.values())
        print(f"{n:{width}}  " + ", ".join(f"{k} {1000 * c / total:.1f}" for k, c in natives.most_common(8)))

    print("\n## Hottest property-cache miss sites (kind function@pc .property xcount)")
    for n in names:
        top = sorted(data[n][3], key=lambda m: -m[4])[:6]
        print(f"{n:{width}}  " + "; ".join(f"{k} {fn}@{pc} .{prop} x{c}" for k, fn, pc, prop, c in top))


if __name__ == "__main__":
    main()
