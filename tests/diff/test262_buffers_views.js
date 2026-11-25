// DataView.prototype.{getFloat16, setFloat16}, TypedArray.prototype.{toReversed, toSorted, with},
// and TypedArray.prototype.{subarray, sort} detached-buffer edge cases.

function errName(fn) {
    try {
        fn();
        return "NO_THROW";
    } catch (e) {
        return e.name;
    }
}

// 1. DataView.prototype.{getFloat16, setFloat16}
{
    const ab = new ArrayBuffer(12);
    const dv = new DataView(ab);
    dv.setFloat16(0, 1.5, false);
    dv.setFloat16(2, -0.0, true);
    dv.setFloat16(4, Infinity, false);
    dv.setFloat16(6, 65504, true);
    dv.setFloat16(8, 0.00000005960464477539063, false); // smallest positive subnormal
    dv.setFloat16(10, NaN, true);

    print("f16 0:", dv.getFloat16(0, false), dv.getUint16(0, false).toString(16));
    print("f16 -0:", Object.is(dv.getFloat16(2, true), -0), dv.getUint16(2, true).toString(16));
    print("f16 inf:", dv.getFloat16(4, false));
    print("f16 max:", dv.getFloat16(6, true));
    print("f16 sub:", dv.getFloat16(8, false));
    print("f16 nan:", Number.isNaN(dv.getFloat16(10, true)));
    print("f16 oob:", errName(() => dv.getFloat16(11)), errName(() => dv.setFloat16(11, 1)));

    structuredClone(ab, { transfer: [ab] });
    print("f16 detached:", errName(() => dv.getFloat16(0)), errName(() => dv.setFloat16(0, 1)));
}

// 2. TypedArray.prototype.{toReversed, toSorted, with}
{
    const a = new Int32Array([3, -1, 2, 0]);
    const rev = a.toReversed();
    const srt = a.toSorted();
    const desc = a.toSorted((x, y) => y - x);
    const w1 = a.with(1, 99);
    const w2 = a.with(-1, 42);
    print("orig:", Array.from(a).join(","));
    print("toReversed:", rev instanceof Int32Array, Array.from(rev).join(","));
    print("toSorted:", srt instanceof Int32Array, Array.from(srt).join(","));
    print("toSorted desc:", Array.from(desc).join(","));
    print("with:", w1 instanceof Int32Array, Array.from(w1).join(","), Array.from(w2).join(","));
    print("with oob:", errName(() => a.with(4, 1)), errName(() => a.with(-5, 1)));
    print("toSorted bad cmp:", errName(() => a.toSorted(123)));

    const f = new Float64Array([0, -0, NaN, -1.5, 2.5]);
    const fs = f.toSorted();
    print("f64 toSorted:", fs[0], Object.is(fs[1], -0), Object.is(fs[2], 0), fs[3], Number.isNaN(fs[4]));

    const bi = new BigInt64Array([10n, -5n, 3n]);
    print("bi toReversed:", Array.from(bi.toReversed()).join(","));
    print("bi toSorted:", Array.from(bi.toSorted()).join(","));
    print("bi toSorted cmp:", Array.from(bi.toSorted((x, y) => (x < y ? 1 : x > y ? -1 : 0))).join(","));
    print("bi with:", Array.from(bi.with(-2, 77n)).join(","));
}

// 3. TypedArray.prototype.subarray on detached buffer evaluates begin/end before throwing TypeError
{
    const ta = new Uint8Array([1, 2, 3, 4]);
    structuredClone(ta.buffer, { transfer: [ta.buffer] });
    const log = [];
    const res = errName(() =>
        ta.subarray(
            { valueOf() { log.push("begin"); return 0; } },
            { valueOf() { log.push("end"); return 2; } }
        )
    );
    print("subarray detached:", res, log.join(","));
}

// 4. TypedArray.prototype.sort when comparator detaches buffer
{
    const ta = new Int32Array([3, 1, 2]);
    let detached = false;
    const ret = ta.sort((a, b) => {
        if (!detached) {
            detached = true;
            structuredClone(ta.buffer, { transfer: [ta.buffer] });
        }
        return a - b;
    });
    print("sort detach:", ret === ta, ta.byteLength);
}
