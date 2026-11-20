// M43: ArrayBuffer and TypedArray semantics vs Node.js

function expectError(fn) {
    try {
        fn();
        return "NO_ERROR";
    } catch (e) {
        return e.name;
    }
}

// 1. All 9 constructors, BYTES_PER_ELEMENT, and prototype hierarchy
const ctors = [
    Int8Array, Uint8Array, Uint8ClampedArray,
    Int16Array, Uint16Array,
    Int32Array, Uint32Array,
    Float32Array, Float64Array,
];
print("bpe:", ctors.map((C) => C.BYTES_PER_ELEMENT + ":" + C.prototype.BYTES_PER_ELEMENT).join(","));

const TA = Object.getPrototypeOf(Uint8Array);
const TAProto = Object.getPrototypeOf(Uint8Array.prototype);
print("TA name:", TA.name, "proto eq:", TA === Object.getPrototypeOf(Int32Array), "proto.proto eq:", TAProto === Object.getPrototypeOf(Float64Array.prototype));
print("call TA:", expectError(() => TA()));
print("new TA:", expectError(() => new TA(4)));
print("call Uint8Array:", expectError(() => Uint8Array(4)));
print("call ArrayBuffer:", expectError(() => ArrayBuffer(4)));

const u8 = new Uint8Array(3);
print("instanceof:", u8 instanceof Uint8Array, u8 instanceof TA, u8 instanceof Object);
print("toStringTag:", Object.prototype.toString.call(u8), Object.prototype.toString.call(Uint8Array.prototype));

// 2. Constructor overloads
print("empty:", new Int16Array().length);
print("len:", new Int16Array(3).join(","));
print("fromTA:", new Int8Array(new Int32Array([127, 128, -129, 255])).join(","));
print("fromIter:", new Uint16Array([10, 20, 65536, -1]).join(","));
print("fromArrayLike:", new Uint8Array({ length: 3, 0: 5, 1: 260, 2: -1 }).join(","));

// ArrayBuffer + view overloads
const ab = new ArrayBuffer(12);
print("ab byteLength:", ab.byteLength, "isView(ab):", ArrayBuffer.isView(ab), "isView(u8):", ArrayBuffer.isView(u8));
const view1 = new Int32Array(ab, 4, 2);
view1[0] = 100;
view1[1] = -200;
print("view1:", view1.byteOffset, view1.byteLength, view1.length, view1.buffer === ab, view1.join(","));
print("bad offset align:", expectError(() => new Int32Array(ab, 2)));
print("bad offset oob:", expectError(() => new Int32Array(ab, 16)));
print("bad len oob:", expectError(() => new Int32Array(ab, 8, 2)));
print("bad ab len align:", expectError(() => new Int32Array(new ArrayBuffer(5))));
print("bad ab neg:", expectError(() => new ArrayBuffer(-1)));

// ArrayBuffer.prototype.slice
const abSlice = ab.slice(4, 8);
print("abSlice:", abSlice.byteLength, new Int32Array(abSlice)[0], abSlice !== ab);

// 3. Numeric coercions & Uint8ClampedArray round-half-to-even
const clamped = new Uint8ClampedArray([0.5, 1.5, 2.5, 3.5, -0.5, 254.5, 255.5, NaN, Infinity, -Infinity]);
print("clamped:", clamped.join(","));

const f32 = new Float32Array([0, -0, NaN, Infinity, -Infinity, 1.5, 1.337]);
print("f32 -0:", Object.is(f32[0], 0), Object.is(f32[1], -0), Number.isNaN(f32[2]), f32[3], f32[4]);
print("f32 prec:", f32[6] !== 1.337, Math.abs(f32[6] - 1.337) < 1e-6);

// 4. Static from / of
print("Uint8Array.of:", Uint8Array.of(1, 2, 257).join(","));
print("Int16Array.from:", Int16Array.from([1, 2, 3], (x, i) => x * 10 + i).join(","));

// 5. Overlapping set() on same buffer
const overlap = new Uint8Array([1, 2, 3, 4, 5, 6]);
overlap.set(overlap.subarray(0, 4), 2);
print("overlap fwd:", overlap.join(","));
overlap.set(overlap.subarray(2, 6), 0);
print("overlap bwd:", overlap.join(","));

const mixedBuf = new ArrayBuffer(8);
const mi32 = new Int32Array(mixedBuf);
const mu8 = new Uint8Array(mixedBuf);
mi32[0] = 300;
mi32[1] = 400;
mu8.set(mi32, 0);
print("mixed overlap:", mu8[0], mu8[1]);

// 6. subarray vs slice
const orig = new Int16Array([10, 20, 30, 40]);
const sub = orig.subarray(1, 3);
const slc = orig.slice(1, 3);
sub[0] = 99;
slc[1] = 88;
print("sub vs slice:", orig.join(","), sub.buffer === orig.buffer, slc.buffer === orig.buffer);

// 7. sort (numeric default + -0 + NaN + custom comparator)
const f64 = new Float64Array([0, -0, NaN, -1, 10, 2, Infinity, -Infinity]);
f64.sort();
print("sort f64:", Array.from(f64).map((x) => (Object.is(x, -0) ? "-0" : String(x))).join(","));
const desc = new Int32Array([3, 1, 4, 1, 5, 9]);
desc.sort((a, b) => b - a);
print("sort desc:", desc.join(","));

// 8. Mutators, search, iteration, callbacks
const m = new Int32Array([1, 2, 3, 4, 5]);
m.fill(7, 1, 4);
print("fill:", m.join(","));
m.set([1, 2, 3, 4, 5]);
m.copyWithin(1, 2, 4);
print("copyWithin:", m.join(","));
m.reverse();
print("reverse:", m.join(","));
print("search:", m.indexOf(4), m.lastIndexOf(4), m.includes(5), m.at(-1));

const mapped = new Int16Array([1, 2, 3]).map((x) => x * 2);
const filtered = mapped.filter((x) => x > 2);
print("map/filter:", mapped.join(","), filtered.join(","), filtered instanceof Int16Array);
print("reduce:", new Uint8Array([1, 2, 3, 4]).reduce((a, b) => a + b, 10));
print("reduceRight:", new Uint8Array([1, 2, 3]).reduceRight((a, b) => a * 10 + b, 0));
print("find:", new Uint8Array([5, 12, 8, 130]).find((x) => x > 10), new Uint8Array([5, 12, 8, 130]).findLastIndex((x) => x > 10));
print("every/some:", new Uint8Array([2, 4, 6]).every((x) => x % 2 === 0), new Uint8Array([1, 3, 4]).some((x) => x % 2 === 0));

const spread = [...new Uint8Array([7, 8, 9])];
const entries = Array.from(new Uint8Array([7, 8]).entries());
print("iter:", spread.join(","), entries.map((e) => e[0] + ":" + e[1]).join(","));

// 9. Canonical numeric index exotic semantics (no prototype walk!)
Uint8Array.prototype[999] = 42;
Uint8Array.prototype[-1] = 42;
Uint8Array.prototype["-0"] = 42;
Uint8Array.prototype["1.5"] = 42;
Uint8Array.prototype["NaN"] = 42;
Uint8Array.prototype["01"] = 42;
const exo = new Uint8Array([10, 20]);
print("exo get:", exo[999], exo[-1], exo["-0"], exo[1.5], exo[NaN], exo["01"]);
print("exo in:", 0 in exo, 999 in exo, -1 in exo, "-0" in exo, "01" in exo);
print("exo del:", delete exo[0], delete exo[999], delete exo[-1], exo[0]);

// 10. Object.keys, for...in, descriptors, integrity
print("keys:", Object.keys(exo).join(","));
const forInKeys = [];
for (const k in exo) {
    if (Object.hasOwn(exo, k)) forInKeys.push(k);
}
print("forIn own:", forInKeys.join(","));
const d0 = Object.getOwnPropertyDescriptor(exo, 0);
print("desc0:", d0.value, d0.writable, d0.enumerable, d0.configurable);

print("freeze non-empty:", expectError(() => Object.freeze(exo)));
print("seal non-empty:", expectError(() => Object.seal(new Uint8Array([1, 2]))));
Object.preventExtensions(exo);
print("preventExt non-empty:", Object.isExtensible(exo), Object.isSealed(exo), Object.isFrozen(exo));

const emptyTa = new Uint8Array(0);
Object.freeze(emptyTa);
print("freeze empty:", Object.isExtensible(emptyTa), Object.isSealed(emptyTa), Object.isFrozen(emptyTa));
