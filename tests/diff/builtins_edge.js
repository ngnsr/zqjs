// 1. Array indices & bounds: -0, NaN, Infinity, -Infinity, fractional, reversed
const a = [10, 20, 30];
print("sliceNegZero", a.slice(-0, 2).join(","));
print("idxNegZero", a.indexOf(20, -0), a.includes(20, -0));
print("sliceNaN", a.slice(NaN, 1).join(","));
print("idxNaN", a.indexOf(20, NaN), a.includes(20, NaN));
print("sliceInf", a.slice(0, Infinity).join(","), a.slice(Infinity).length, a.slice(-Infinity, 1).join(","));
print("incInf", a.includes(10, Infinity), a.includes(10, -Infinity), a.indexOf(10, Infinity), a.indexOf(10, -Infinity));
print("sliceFrac", a.slice(1.9, 2.9).join(","), a.slice(-1.9).join(","));
print("sliceRev", a.slice(2, 1).length, a.slice(-1, -2).length);

// 2. Array search: indexOf vs includes, NaN, +0/-0, omitted vs explicit undefined fromIndex
print("nanSearch", [NaN].indexOf(NaN), [NaN].includes(NaN));
print("zeroSearch", [-0].indexOf(+0), [0].includes(-0));
print("negFrom", [1, 2, 3, 2].indexOf(2, -2), [1, 2, 3].includes(1, -100));
print("undefFromIdx", [10, 20, 30].indexOf(20), [10, 20, 30].indexOf(20, undefined));
print("undefFromInc", [10, 20, 30].includes(20), [10, 20, 30].includes(20, undefined));

// 3. String indices & UTF-16 boundaries
const sp = "\uD83D\uDE00a";
print("surr", sp.charCodeAt(0), sp.charCodeAt(1), sp.charAt(1) === "\uDE00", sp.slice(1, 3) === "\uDE00a");
print("strSlice", "abcd".slice(-2, -1), "abcd".slice(3, 1), "abcd".charAt(1.9), "abcd".charCodeAt(NaN));
print("strEmpty", "abc".indexOf("", Infinity), "abc".includes("", Infinity), "abc".indexOf("", -5), "abc".includes("", -5));

// 4. Callbacks: reduce non-callable, thisArg object, native callback
for (let i = 0; i < 2; i++) {
  let name = "";
  try {
    if (i === 0) [].reduce(123);
    if (i === 1) [99].reduce(123);
  } catch (e) {
    name = e.name;
  }
  print("redNonFn", i, name);
}
print("thisObj", [1, 2].map(function (v) { return v + this.x; }, { x: 10 }).join(","));
print("nativeCb", [1, -2, -3].map(Math.abs).join(","));

// 5. Empty Map/Set forEach
let emptyCalls = 0;
print("emptyMap", new Map().forEach(function () { emptyCalls++; }), emptyCalls);
print("emptySet", new Set().forEach(function () { emptyCalls++; }), emptyCalls);

// 6. Map.prototype.forEach: 5 individual live-mutation cases
// Case A: delete unvisited entry
const mDel = new Map([["a", 1], ["b", 2], ["c", 3]]);
const mDelLog = [];
mDel.forEach(function (v, k) {
  mDelLog.push(k + ":" + v);
  if (k === "a") mDel.delete("b");
});
print("mDelUnvisited", mDelLog.join(","));

// Case B: update existing unvisited entry
const mUpd = new Map([["a", 1], ["b", 2]]);
const mUpdLog = [];
mUpd.forEach(function (v, k) {
  mUpdLog.push(k + ":" + v);
  if (k === "a") mUpd.set("b", 20);
});
print("mUpdExisting", mUpdLog.join(","));

// Case C: add new entry during iteration
const mAdd = new Map([["a", 1]]);
const mAddLog = [];
mAdd.forEach(function (v, k) {
  mAddLog.push(k + ":" + v);
  if (k === "a") mAdd.set("b", 2);
});
print("mAddNew", mAddLog.join(","));

// Case D: clear() and insert new entries
const mClr = new Map([["a", 1], ["b", 2]]);
const mClrLog = [];
mClr.forEach(function (v, k) {
  mClrLog.push(k + ":" + v);
  if (k === "a") {
    mClr.clear();
    mClr.set("c", 3);
    mClr.set("d", 4);
  }
});
print("mClrInsert", mClrLog.join(","));

// Case E: delete and reinsert current entry
const mRe = new Map([["a", 1], ["b", 2]]);
const mReLog = [];
let mReDone = false;
mRe.forEach(function (v, k) {
  mReLog.push(k + ":" + v);
  if (k === "a" && !mReDone) {
    mReDone = true;
    mRe.delete("a");
    mRe.set("a", 10);
  }
});
print("mDelReinsert", mReLog.join(","));

// 7. Set.prototype.forEach: 5 individual live-mutation cases
// Case A: delete unvisited entry
const sDel = new Set([1, 2, 3]);
const sDelLog = [];
sDel.forEach(function (v) {
  sDelLog.push(v);
  if (v === 1) sDel.delete(2);
});
print("sDelUnvisited", sDelLog.join(","));

// Case B: add new entry during iteration
const sAdd = new Set([1]);
const sAddLog = [];
sAdd.forEach(function (v) {
  sAddLog.push(v);
  if (v === 1) sAdd.add(2);
});
print("sAddNew", sAddLog.join(","));

// Case C: clear() and insert new entries
const sClr = new Set([1, 2]);
const sClrLog = [];
sClr.forEach(function (v) {
  sClrLog.push(v);
  if (v === 1) {
    sClr.clear();
    sClr.add(3);
    sClr.add(4);
  }
});
print("sClrInsert", sClrLog.join(","));

// Case D: delete and reinsert current entry
const sRe = new Set([1, 2]);
const sReLog = [];
let sReDone = false;
sRe.forEach(function (v) {
  sReLog.push(v);
  if (v === 1 && !sReDone) {
    sReDone = true;
    sRe.delete(1);
    sRe.add(1);
  }
});
print("sDelReinsert", sReLog.join(","));

// Case E: NaN and +0/-0 in Set.forEach
const sSvz = new Set([NaN, 0 / 0, -0, +0]);
const sSvzLog = [];
sSvz.forEach(function (v) {
  sSvzLog.push(v);
});
print("sSvz", sSvzLog.join(","));
