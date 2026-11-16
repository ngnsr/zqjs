// Array.prototype.forEach
const feArr = [10, 20, 30];
const feCtx = { mult: 2 };
const feLog = [];
const feRet = feArr.forEach(function (v, i, a) {
  feLog.push(v * this.mult + ":" + i + ":" + (a === feArr));
}, feCtx);
print(feRet, feLog.join(","));

// Array.prototype.map
const mapped = [1, 2, 3].map(function (v, i) {
  return v * 10 + i + this.off;
}, { off: 100 });
print(mapped.join(","));

// Nested map
const matrix = [[1, 2], [3, 4]];
const doubled = matrix.map(function (row) {
  return row.map(function (x) { return x * 2; });
});
print(doubled[0].join(","), doubled[1].join(","));

// Array.prototype.filter (preserves original elements across allocations)
const objs = [{ id: 1, keep: true }, { id: 2, keep: false }, { id: 3, keep: true }];
const filtered = objs.filter(function (o, i) {
  return o.keep && i >= 0;
});
print(filtered.length, filtered[0].id, filtered[1].id, filtered[0] === objs[0]);

// Array.prototype.reduce (with/without initialValue, single element, empty TypeError)
print([1, 2, 3, 4].reduce(function (acc, v, i) { return acc + v * (i + 1); }, 10));
print([1, 2, 3, 4].reduce(function (acc, v) { return acc + v; }));
let singleCalled = false;
print([99].reduce(function () { singleCalled = true; return 0; }), singleCalled);
try {
  [].reduce(function (a, b) { return a + b; });
} catch (e) {
  print("emptyReduce", e.name);
}

// Growing array stops at captured initial length; shrinking skips missing indices
const grow = [1, 2, 3];
const growSeen = [];
grow.forEach(function (v) {
  growSeen.push(v);
  if (v === 1) grow.push(4, 5);
});
print("grow", growSeen.join(","), grow.length);

const shrink = [1, 2, 3, 4];
const shrinkSeen = [];
shrink.forEach(function (v) {
  shrinkSeen.push(v);
  if (v === 1) shrink.pop();
});
print("shrinkFE", shrinkSeen.join(","));

const shrinkFilt = [1, 2, 3, 4].filter(function (v, i, a) {
  if (v === 1) a.pop();
  return true;
});
print("shrinkFilt", shrinkFilt.join(","));

const shrinkRed = [10, 20, 30].reduce(function (acc, v, i, a) {
  if (i === 1) a.pop();
  return acc + v;
}, 0);
print("shrinkRed", shrinkRed);

// Non-callable callback throws TypeError
for (let k = 0; k < 6; k++) {
  let caught = "";
  try {
    if (k === 0) [1].forEach(123);
    if (k === 1) [1].map(null);
    if (k === 2) [1].filter({});
    if (k === 3) [1].reduce(undefined);
    if (k === 4) new Map().forEach("x");
    if (k === 5) new Set().forEach(false);
  } catch (e) {
    caught = e.name;
  }
  if (caught !== "TypeError") print("FAIL_CB", k, caught);
}

// Callback exception unwinds cleanly
try {
  [1, 2, 3].map(function (v) {
    if (v === 2) throw "stop-map";
    return v;
  });
} catch (e) {
  print("caught", e);
}

// Map.prototype.forEach: order, thisArg, NaN/-0, and all 5 live-mutation cases
const m1 = new Map([[NaN, "nan"], [-0, "zero"], ["a", 1]]);
const m1Log = [];
const m1Ctx = { tag: "M" };
const m1Ret = m1.forEach(function (v, k, col) {
  m1Log.push(this.tag + ":" + k + "=" + v + ":" + (col === m1));
}, m1Ctx);
print(m1Ret, m1Log.join("|"));

// 1) delete unvisited, 2) update existing, 3) add new, 5) delete & reinsert current
const mMut = new Map([["a", 1], ["b", 2], ["c", 3]]);
const mMutLog = [];
let readded = false;
mMut.forEach(function (v, k) {
  mMutLog.push(k + ":" + v);
  if (k === "a" && !readded) {
    readded = true;
    mMut.delete("b");          // delete unvisited
    mMut.set("c", 30);         // update existing unvisited
    mMut.set("d", 4);          // add new
    mMut.delete("a");          // delete current
    mMut.set("a", 10);         // reinsert current
  }
});
print("mMut", mMutLog.join(","));

// 4) Map clear() followed by insertion during forEach
const mClr = new Map([["x", 1], ["y", 2]]);
const mClrLog = [];
mClr.forEach(function (v, k) {
  mClrLog.push(k + ":" + v);
  if (k === "x") {
    mClr.clear();
    mClr.set("z", 3);
  }
});
print("mClr", mClrLog.join(","));

// Set.prototype.forEach: all 5 live-mutation cases
const sMut = new Set(["a", "b", "c"]);
const sMutLog = [];
let sReadded = false;
const sRet = sMut.forEach(function (v, k, col) {
  sMutLog.push(v + ":" + (v === k) + ":" + (col === sMut));
  if (v === "a" && !sReadded) {
    sReadded = true;
    sMut.delete("b");          // delete unvisited
    sMut.add("d");             // add new
    sMut.delete("a");          // delete current
    sMut.add("a");             // reinsert current
  }
});
print(sRet, "sMut", sMutLog.join(","));

// Set clear() followed by insertion during forEach
const sClr = new Set([1, 2]);
const sClrLog = [];
sClr.forEach(function (v) {
  sClrLog.push(v);
  if (v === 1) {
    sClr.clear();
    sClr.add(99);
  }
});
print("sClr", sClrLog.join(","));
