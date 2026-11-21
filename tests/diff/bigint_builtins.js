// BigInt() conversions and non-constructability
try { new BigInt(1); } catch (e) { print(e.name); }
print(BigInt(0), BigInt(-0), BigInt(42), BigInt(-42));
print(BigInt(true), BigInt(false));
print(BigInt(""), BigInt("   "), BigInt(" 123 "), BigInt("+42"), BigInt("-99"));
print(BigInt("0xff"), BigInt("0o77"), BigInt("0b1010"));
print(BigInt({ valueOf() { return 10n; } }));
print(Number(9007199254740992n), Number(9007199254740993n), Number(9007199254740995n));
print(Number(1n << 2000n), Number(-(1n << 2000n)));

for (const bad of [1.5, NaN, Infinity, -Infinity]) {
  try { BigInt(bad); } catch (e) { print(e.name); }
}
for (const bad of ["1_0", "-0x10", "+0x10", "0x", "abc"]) {
  try { BigInt(bad); } catch (e) { print(e.name); }
}
for (const bad of [undefined, null, Symbol("x")]) {
  try { BigInt(bad); } catch (e) { print(e.name); }
}

// BigInt.asIntN / BigInt.asUintN
print(BigInt.asIntN(8, 255n), BigInt.asIntN(8, 127n), BigInt.asIntN(8, -128n), BigInt.asIntN(8, -129n));
print(BigInt.asUintN(8, -1n), BigInt.asUintN(8, 256n), BigInt.asUintN(0, 123n), BigInt.asIntN(0, 123n));
print(BigInt.asIntN(100, -1n), BigInt.asUintN(100, -1n));

// BigInt.prototype.toString(2..36) & valueOf & toStringTag
const big = (1n << 70n) + 12345n;
print(big.toString(), big.toString(2), big.toString(8), big.toString(16), big.toString(36));
print((-big).toString(16), (0n).toString(36), (10n).valueOf());
print(Object.prototype.toString.call(1n));
for (const r of [1, 37, 0]) {
  try { (1n).toString(r); } catch (e) { print(e.name); }
}

// BigInt64Array & BigUint64Array
const i64 = new BigInt64Array(4);
i64[0] = (1n << 63n) - 1n;
i64[1] = 1n << 63n; // wraps to -2^63
i64[2] = -1n;
i64[3] = 5n;
print(i64.BYTES_PER_ELEMENT, i64.length, i64.byteLength);
print(i64[0], i64[1], i64[2], i64[3]);

const u64 = new BigUint64Array([10n, -1n, 0n, 3n]);
print(u64[0], u64[1], u64[2], u64[3]);
u64.sort();
print(u64.join(","));
i64.sort();
print(i64.join(","));

const sub = i64.subarray(1, 3);
print(sub.length, sub[0], sub[1]);
u64.set([7n, 8n], 1);
print(u64.join(","));
print(u64.includes(8n), u64.indexOf(8n));

try { i64[0] = 1; } catch (e) { print(e.name); }
try { u64[0] = 1; } catch (e) { print(e.name); }
try { new BigInt64Array(new Int32Array(2)); } catch (e) { print(e.name); }

// DataView getBigInt64 / setBigInt64 / getBigUint64 / setBigUint64
const dv = new DataView(new ArrayBuffer(16));
dv.setBigInt64(1, -0x0102030405060708n); // big-endian, unaligned
print(dv.getBigInt64(1), dv.getBigInt64(1, true));
dv.setBigUint64(3, 0xfedcba9876543210n, true); // little-endian, unaligned
print(dv.getBigUint64(3, true).toString(16), dv.getBigUint64(3, false).toString(16));
try { dv.getBigInt64(9); } catch (e) { print(e.name); }
try { dv.setBigUint64(9, 1n); } catch (e) { print(e.name); }
try { dv.setBigInt64(0, 123); } catch (e) { print(e.name); }
