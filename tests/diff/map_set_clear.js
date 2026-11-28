// Map/Set clear() drops entries; iterators and forEach loops must still visit entries added
// after a clear (they restart at the new start), and exhausted iterators stay done.
const out = [];
const log = (...a) => out.push(a.join(" "));
{ const m = new Map([[1, "a"], [2, "b"], [3, "c"]]); const it = m.keys(); log("k1", it.next().value); m.clear(); m.set(9, "z"); m.set(8, "y"); log("after-clear", [...it].join(",")); }
{ const m = new Map([[1, 1], [2, 2]]); const seen = []; m.forEach((v, k) => { seen.push(k); if (k === 1) { m.clear(); m.set(5, 5); m.set(6, 6); } }); log("forEach-clear", seen.join(",")); }
{ const s = new Set([1, 2, 3]); const seen = []; let once = true; for (const x of s) { seen.push(x); if (x === 1 && once) { once = false; s.clear(); s.add(7); s.add(1); } } log("set-forof-clear", seen.join(",")); }
{ const s = new Set([1, 2, 3]); const seen = []; s.forEach((x) => { seen.push(x); if (x === 2) { s.clear(); s.add(4); } }); log("set-forEach-clear", seen.join(",")); }
{ const m = new Map(); for (let t = 0; t < 50; t++) { m.clear(); for (let i = 0; i < 10; i++) m.set(i + t, i); } log("refill", m.size, [...m.keys()].join(",")); }
{ const m = new Map([[1, 1], [2, 2], [3, 3]]); const it = m.entries(); m.delete(1); m.set(1, 10); log("delete-readd", [...it].map(([k, v]) => k + ":" + v).join(",")); }
{ const s = new Set([1, 2]); const it = s.values(); log("s1", it.next().value); s.clear(); s.clear(); s.add(3); log("double-clear", [...it].join(","), s.size); }
{ const m = new Map([[1, 1]]); const it = m.keys(); m.clear(); log("exhausted-after-clear", JSON.stringify(it.next())); m.set(2, 2); log("still-done", JSON.stringify(it.next())); }
{ const m = new Map([[1, 1]]); const it = m.keys(); log("n", JSON.stringify(it.next()), JSON.stringify(it.next())); m.clear(); m.set(3, 3); log("done-stays-done", JSON.stringify(it.next())); }
{ const s = new Set([1, 2, 3, 4]); const a = new Set([2, 3]); log("union", [...s.union(a)].join(","), "inter", [...s.intersection(a)].join(","), "diff", [...s.difference(a)].join(",")); }
{ const m = new Map(); m.set(NaN, 1); m.set(-0, 2); m.clear(); m.set(NaN, 3); log("nan", m.get(NaN), m.has(0), m.size); }
{ const m = new Map([[1, 1], [2, 2]]); m.clear(); log("cleared-size", m.size, JSON.stringify([...m])); const c = structuredClone(new Map([[1, { a: 1 }]])); log("clone", c.get(1).a); }
print(out.join("\n"));
{ const m = new Map(); for (let t = 0; t < 2000; t++) { m.clear(); for (let i = 0; i < 20; i++) m.set(i, t); } let s = 0; m.forEach((v) => { s += v; }); print("churn", m.size, s); }
