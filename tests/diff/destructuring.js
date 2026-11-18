// Array destructuring with iterables (Array, Map, Set, String with surrogate pairs, Iterator)
const [a, b, c] = [10, 20, 30];
print(a, b, c);

const s = new Set(["x", "y", "z"]);
const [s1, , s3] = s;
print(s1, s3);

const m = new Map([["k1", 100], ["k2", 200]]);
const [[mk1, mv1], [mk2, mv2]] = m;
print(mk1, mv1, mk2, mv2);

// Surrogate pair + lone surrogate
const [c0, c1, c2, c3] = "A\uD83D\uDE00B";
print(c0, c1.length, c1.charCodeAt(0), c2, c3);

const it = [7, 8, 9].values();
const [i0, ...irest] = it;
print(i0, irest.join(","));

// Holes & nested rest
const [, h1, , ...[r0, r1]] = [1, 2, 3, 4, 5];
print(h1, r0, r1);

// Lazy left-to-right defaults with side-effect logs
const log = [];
function def(tag, val) {
  log.push(tag);
  return val;
}
const [
  d1 = def("d1", 1),
  d2 = def("d2", 2),
  d3 = def("d3", 3),
  d4 = def("d4", 4),
] = [10, undefined, null];
print(d1, d2, d3, d4, log.join(","));

log.length = 0;
const {
  x: ox = def("ox", 11),
  y: [oy = def("oy", 22)] = def("y-outer", [undefined]),
  z: oz = def("oz", 33),
} = { x: 0, y: undefined };
print(ox, oy, oz, log.join(","));

// Object destructuring: shorthand, rename, computed keys, rest in Object.keys order
const dyn = "b";
const src = { a: 1, b: 2, 1: 10, 0: 20, c: 3, d: 4 };
const { a: ra, [dyn]: rb, 0: r0k, ...restObj } = src;
print(ra, rb, r0k, Object.keys(restObj).join(","), restObj[1], restObj.c, restObj.d);

// Object rest on string
const { 0: firstCh, ...restStr } = "abc";
print(firstCh, Object.keys(restStr).join(","), restStr[1], restStr[2]);

// Destructuring null/undefined throws TypeError
for (const bad of [null, undefined]) {
  try {
    const {} = bad;
    print("unexpected");
  } catch (e) {
    print(e.name);
  }
  try {
    const [] = bad;
    print("unexpected");
  } catch (e) {
    print(e.name);
  }
}

// Assignment destructuring: swap, member targets, nested, evaluation order
let p = 1, q = 2;
[p, q] = [q, p];
print(p, q);

const target = { arr: [0, 0] };
let idx = 0;
({ a: target.prop, b: [target.arr[idx++], target.arr[idx++]] } = { a: "ok", b: [42, 99] });
print(target.prop, target.arr.join(","), idx);

// for...of destructuring with per-iteration closures
const fns = [];
for (const { k, v = k * 10 } of [{ k: 1 }, { k: 2, v: 200 }, { k: 3 }]) {
  fns.push(() => k + ":" + v);
}
print(fns.map(fn => fn()).join(","));

const fns2 = [];
for (let [u, v] of [[1, 2], [3, 4]]) {
  fns2.push(() => u + v);
  u += 10;
}
print(fns2.map(fn => fn()).join(","));

// for...of assignment destructuring
let fa, fb;
const pairs = [];
for ([fa, fb = 0] of [[1], [2, 3]]) {
  pairs.push(fa + ":" + fb);
}
print(pairs.join(","));

// catch destructuring
try {
  throw { code: 500, detail: ["fail"] };
} catch ({ code, detail: [msg], extra = "none" }) {
  print(code, msg, extra);
}

// member targets in for...of heads (was Unsupported before M26)
const holder = { x: 0 }, slots = [];
for (holder.x of [1, 2, 3]) slots.push(holder.x);
for (slots[3] of ["last"]);
print(holder.x, slots.join(","));
