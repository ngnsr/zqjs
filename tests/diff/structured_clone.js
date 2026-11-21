// M51 (D81): structuredClone(value, options?) and ArrayBuffer transfer/detachment.

// 1. Metadata & primitives
print(typeof structuredClone);
print(structuredClone(undefined), structuredClone(null), structuredClone(true), structuredClone(false));
print(Object.is(structuredClone(-0), -0), Number.isNaN(structuredClone(NaN)));
print(structuredClone(42), structuredClone("hello \u00e9"), structuredClone(123456789012345678901234567890n));

// 2. Plain objects, arrays, getters, non-enumerable & symbol props, prototype reset
class Box {
  constructor(v) { this.v = v; }
}
const sym = Symbol("hidden");
const src = new Box(10);
let getterCalls = 0;
Object.defineProperty(src, "computed", {
  enumerable: true,
  get() { getterCalls++; return this.v * 2; },
});
Object.defineProperty(src, "secret", { enumerable: false, value: 99 });
src[sym] = "symval";
const clonedObj = structuredClone(src);
print(
  clonedObj.v,
  clonedObj.computed,
  getterCalls,
  "secret" in clonedObj,
  sym in clonedObj,
  !(clonedObj instanceof Box),
  Object.getPrototypeOf(clonedObj) !== Box.prototype,
  Object.getOwnPropertyDescriptor(clonedObj, "computed").value
);

const arr = [1, { nested: [2, 3] }];
arr.extra = "yes";
const clonedArr = structuredClone(arr);
print(Array.isArray(clonedArr), clonedArr.length, clonedArr[0], clonedArr[1].nested.join(","), clonedArr.extra);
print(clonedArr[1] !== arr[1]);

// 3. Circular references & shared-reference identity
const cyc = { name: "root" };
cyc.self = cyc;
const shared = { tag: "shared" };
cyc.a = shared;
cyc.b = shared;
const clonedCyc = structuredClone(cyc);
print(clonedCyc !== cyc, clonedCyc.self === clonedCyc, clonedCyc.a === clonedCyc.b, clonedCyc.a !== shared, clonedCyc.a.tag);

const cycArr = [];
cycArr.push(cycArr);
const clonedCycArr = structuredClone(cycArr);
print(clonedCycArr !== cycArr, clonedCycArr[0] === clonedCycArr);

const cycMap = new Map();
cycMap.set("self", cycMap);
cycMap.set(shared, 123);
const clonedMap = structuredClone(cycMap);
print(clonedMap !== cycMap, clonedMap.get("self") === clonedMap, clonedMap.size);

const cycSet = new Set();
cycSet.add(cycSet);
cycSet.add("x");
const clonedSet = structuredClone(cycSet);
print(clonedSet !== cycSet, clonedSet.has(clonedSet), clonedSet.has("x"), clonedSet.size);

// 4. Date & RegExp
const dValid = new Date(1700000000000);
const dInvalid = new Date(NaN);
const cdValid = structuredClone(dValid);
const cdInvalid = structuredClone(dInvalid);
print(Object.prototype.toString.call(cdValid), cdValid !== dValid, cdValid.getTime(), Number.isNaN(cdInvalid.getTime()));

const rx = /abc(\d+)/gi;
rx.lastIndex = 5;
const crx = structuredClone(rx);
print(Object.prototype.toString.call(crx), crx !== rx, crx.source, crx.flags, crx.lastIndex);

// 5. Error & TypeError with cause
const err = new TypeError("bad input", { cause: { code: 42 } });
const cerr = structuredClone(err);
print(Object.prototype.toString.call(cerr), cerr !== err, cerr.name, cerr.message, cerr.cause.code);

// 6. ArrayBuffer, DataView, and all 11 TypedArray kinds (with shared buffer identity)
const ab = new ArrayBuffer(16);
const u8 = new Uint8Array(ab, 0, 8);
const i16 = new Int16Array(ab, 8, 4);
const dv = new DataView(ab, 4, 8);
u8[0] = 0xaa;
u8[1] = 0xbb;
i16[0] = -1234;
const clonedViews = structuredClone({ ab, u8, i16, dv });
print(
  clonedViews.ab !== ab,
  clonedViews.u8.buffer === clonedViews.ab,
  clonedViews.i16.buffer === clonedViews.ab,
  clonedViews.dv.buffer === clonedViews.ab,
  clonedViews.u8[0],
  clonedViews.u8[1],
  clonedViews.i16[0],
  clonedViews.dv.byteOffset,
  clonedViews.dv.byteLength
);
clonedViews.u8[0] = 0x11;
print(u8[0], clonedViews.u8[0]);

const bi64 = new BigInt64Array([-9007199254740993n, 42n]);
const bu64 = new BigUint64Array([18446744073709551615n]);
const cbi = structuredClone([bi64, bu64]);
print(Object.prototype.toString.call(cbi[0]), cbi[0][0], cbi[0][1], Object.prototype.toString.call(cbi[1]), cbi[1][0]);

for (const Ctor of [Int8Array, Uint8Array, Uint8ClampedArray, Int16Array, Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array]) {
  const ta = new Ctor([1, 2, 3]);
  const cta = structuredClone(ta);
  print(Object.prototype.toString.call(cta), cta !== ta, cta.length, cta[0], cta[2]);
}

// 7. options.transfer & detached semantics
const tab = new ArrayBuffer(8);
const tview = new Uint8Array(tab);
tview[0] = 77;
tview[7] = 88;
const tdv = new DataView(tab);
const transferred = structuredClone({ buf: tab, view: tview }, { transfer: [tab] });
print(tab.byteLength, tview.length, tview.byteLength, tview.byteOffset, tview[0]);
tview[0] = 99;
print(tview[0], transferred.buf.byteLength, transferred.view[0], transferred.view[7]);

for (const [label, fn] of [
  ["ab.slice", () => tab.slice(0)],
  ["ta.subarray", () => tview.subarray(0, 1)],
  ["ta.slice", () => tview.slice(0, 1)],
  ["ta.set", () => tview.set([1])],
  ["ta.sort", () => tview.sort()],
  ["dv.byteLength", () => tdv.byteLength],
  ["dv.getUint8", () => tdv.getUint8(0)],
  ["dv.setUint8", () => tdv.setUint8(0, 1)],
]) {
  try { fn(); print(label, "NO_THROW"); } catch (e) { print(label, e.name); }
}

// Transfer errors: duplicate, already-detached, non-transferable, detached clone
for (const [label, fn] of [
  ["dup-transfer", () => { const b = new ArrayBuffer(4); structuredClone(b, { transfer: [b, b] }); }],
  ["detached-transfer", () => structuredClone(tab, { transfer: [tab] })],
  ["non-transferable", () => structuredClone({}, { transfer: [{}] })],
  ["detached-clone", () => structuredClone(tab)],
  ["detached-view-clone", () => structuredClone(tview)],
  ["detached-dv-clone", () => structuredClone(tdv)],
]) {
  try { fn(); print(label, "NO_THROW"); } catch (e) { print(label, e.name); }
}

// Error during cloning must NOT detach buffers in transfer list!
const safeAb = new ArrayBuffer(4);
new Uint8Array(safeAb)[0] = 55;
try {
  structuredClone({ ok: safeAb, bad: Symbol("nope") }, { transfer: [safeAb] });
} catch (e) {
  print("safe-on-err", e.name, safeAb.byteLength, new Uint8Array(safeAb)[0]);
}

// 8. Non-cloneable values -> DataCloneError
for (const [label, v] of [
  ["symbol", Symbol("s")],
  ["fn", () => 1],
  ["proxy", new Proxy({}, {})],
  ["weakmap", new WeakMap()],
  ["weakset", new WeakSet()],
]) {
  try { structuredClone(v); print(label, "NO_THROW"); } catch (e) { print(label, e.name); }
}
