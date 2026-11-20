// M43: DataView semantics vs Node.js

function expectError(fn) {
    try {
        fn();
        return "NO_ERROR";
    } catch (e) {
        return e.name;
    }
}

print("call DataView:", expectError(() => DataView(new ArrayBuffer(8))));
print("bad arg:", expectError(() => new DataView({})));

const ab = new ArrayBuffer(16);
const dv = new DataView(ab, 2, 12);
print("dv props:", dv.buffer === ab, dv.byteOffset, dv.byteLength, ArrayBuffer.isView(dv));
print("toStringTag:", Object.prototype.toString.call(dv));
print("oob ctor:", expectError(() => new DataView(ab, 17)), expectError(() => new DataView(ab, 10, 8)));

// Unaligned big-endian (default) and little-endian reads/writes
dv.setInt8(0, -42);
dv.setUint8(1, 250);
print("i8/u8:", dv.getInt8(0), dv.getUint8(1));

dv.setInt16(1, -12345);
print("i16 BE:", dv.getInt16(1), dv.getInt16(1, false), dv.getUint8(1), dv.getUint8(2));
dv.setInt16(1, -12345, true);
print("i16 LE:", dv.getInt16(1, true), dv.getUint8(1), dv.getUint8(2));

dv.setUint16(3, 50000);
print("u16 BE/LE:", dv.getUint16(3), dv.getUint16(3, true));

dv.setInt32(2, -0x12345678);
print("i32 BE:", dv.getInt32(2), dv.getUint8(2), dv.getUint8(5));
dv.setUint32(2, 0x89abcdef, true);
print("u32 LE:", dv.getUint32(2, true), dv.getUint8(2), dv.getUint8(5));

function hex(u) {
    const digits = "0123456789abcdef";
    let s = "";
    for (let shift = 28; shift >= 0; shift -= 4) {
        const nibble = (u >>> shift) & 0xf;
        if (s.length > 0 || nibble !== 0 || shift === 0) s += digits[nibble];
    }
    return s;
}

// Float32 and Float64 IEEE-754 bit patterns
dv.setFloat32(0, 1.5, false);
print("f32 BE:", dv.getFloat32(0, false), hex(dv.getUint32(0, false)));
dv.setFloat32(0, -0, true);
print("f32 -0:", Object.is(dv.getFloat32(0, true), -0), hex(dv.getUint32(0, true)));

dv.setFloat64(4, Math.PI, false);
print("f64 BE:", dv.getFloat64(4, false) === Math.PI, hex(dv.getUint32(4, false)), hex(dv.getUint32(8, false)));

// OOB access
print("oob get:", expectError(() => dv.getInt8(12)), expectError(() => dv.getInt32(9)), expectError(() => dv.getFloat64(5)));
print("oob set:", expectError(() => dv.setUint16(11, 1)), expectError(() => dv.setFloat64(-1, 1)));

// Shared buffer visibility with TypedArray
const shared = new ArrayBuffer(4);
const sd = new DataView(shared);
const su8 = new Uint8Array(shared);
sd.setUint32(0, 0x01020304, false);
print("shared:", su8[0], su8[1], su8[2], su8[3]);
su8[0] = 0xff;
print("shared back:", hex(sd.getUint32(0, false)));
