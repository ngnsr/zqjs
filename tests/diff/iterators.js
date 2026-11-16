// Array, keys, values, entries
let arrOut = [];
for (const x of [10, 20, 30]) arrOut.push(x);
for (const k of ["a", "b"].keys()) arrOut.push(k);
for (const e of ["a", "b"].entries()) arrOut.push(e[0] + ":" + e[1]);
print(arrOut.join(","));

// Map & Set iterators
let m = new Map([["a", 1], ["b", 2]]);
let mOut = [];
for (const e of m) mOut.push(e[0] + "=" + e[1]);
for (const k of m.keys()) mOut.push("k:" + k);
for (const v of m.values()) mOut.push("v:" + v);
print(mOut.join(","));

let s = new Set([10, 20, 10]);
let sOut = [];
for (const v of s) sOut.push(v);
for (const e of s.entries()) sOut.push(e[0] + ":" + e[1]);
print(sOut.join(","));

// String UTF-16 surrogate pairs & lone surrogates
let str = "A\uD83D\uDE00\uD800B";
let chars = [];
for (const ch of str) {
  chars.push(ch.length + ":" + ch.charCodeAt(0));
}
print(chars.join(","));

// Live Map mutation: delete unvisited, re-insert at end, insert new during iteration
let liveMap = new Map([["a", 1], ["b", 2], ["c", 3]]);
let seen = [];
for (const e of liveMap) {
  seen.push(e[0] + "=" + e[1]);
  if (e[0] === "a" && e[1] === 1) {
    liveMap.delete("b");
    liveMap.set("d", 4);
    liveMap.delete("a");
    liveMap.set("a", 99);
  }
}
print(seen.join(","));

// clear() followed by insertion mid-iteration on Map and Set
let cm = new Map([["x", 1], ["y", 2]]);
let cmi = cm.entries();
let r1 = cmi.next();
cm.clear();
cm.set("z", 3);
let r2 = cmi.next();
let r3 = cmi.next();
cm.set("after", 4);
let r4 = cmi.next(); // permanently exhausted!
print(r1.value[0], r1.done, r2.value[0], r2.done, r3.value, r3.done, r4.value, r4.done);

let cs = new Set([1, 2]);
let csi = cs.values();
print(csi.next().value);
cs.clear();
cs.add(99);
print(csi.next().value, csi.next().done);
cs.add(100);
print(csi.next().done);

// Control flow: break, continue, return, try/catch, per-iteration const closure capture
let fns = [];
for (const x of [1, 2, 3, 4, 5]) {
  if (x === 2) continue;
  if (x === 5) break;
  fns.push(function () { return x; });
}
let cap = [];
for (let i = 0; i < fns.length; i++) cap.push(fns[i]());
print(cap.join(","));

function findFirstEven(xs) {
  for (const x of xs) {
    if (x % 2 === 0) return x;
  }
  return -1;
}
print(findFirstEven([1, 3, 4, 6]), findFirstEven([1, 3]));

try {
  for (const x of [10, 20, 30]) {
    if (x === 20) throw "boom-" + x;
  }
} catch (e) {
  print(e);
}

// General iterables in Map/Set constructors
let sFromMap = new Set(m.keys());
let sFromStr = new Set("aba\uD83D\uDE00");
let mFromMap = new Map(m.entries());
print(sFromMap.size, sFromMap.has("a"), sFromStr.size, sFromStr.has("\uD83D\uDE00"), mFromMap.get("b"));

// Nested for...of loops (verifying distinct hidden iterator slots + break/continue)
let nested = [];
for (const a of [1, 2, 3]) {
  if (a === 2) continue;
  for (const b of ["x", "y", "z"]) {
    if (b === "z") break;
    nested.push(a + b);
  }
}
print(nested.join(","));

// Non-iterables & TDZ
try { for (const x of 123) {} } catch (e) { print(e.name); }
try { for (const x of null) {} } catch (e) { print(e.name); }
try { for (let x of x) {} } catch (e) { print(e.name); }
