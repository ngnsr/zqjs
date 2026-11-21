// Literals: decimal, hex, octal, binary, separators
print(0n, -0n, 123_456n, 0xff_00n, 0o77n, 0b1010_0101n);
print(typeof 1n, typeof 0n, !!0n, !!1n, !!(-1n));

// Large multi-limb arithmetic (+, -, *, /, %, **, negative quotients/remainders, Knuth D)
const a = (1n << 192n) + 123456789012345678901234567890n;
const b = (1n << 128n) + 9876543210987654321n;
print(a + b);
print(a - b);
print(b - a);
print(a * b);
print(a / b, a % b);
print((-a) / b, (-a) % b);
print(a / (-b), a % (-b));
print((-a) / (-b), (-a) % (-b));
print(2n ** 130n);
print((-3n) ** 5n, (-3n) ** 4n, 0n ** 0n, 1n ** 1000n, (-1n) ** 1001n);

for (const fn of [() => 1n / 0n, () => 1n % 0n, () => 2n ** -1n]) {
  try { fn(); } catch (e) { print(e.name); }
}

// Bitwise: ~, &, |, ^, <<, >> on positive and negative
print(~0n, ~1n, ~(-1n), ~(-42n), ~(1n << 100n));
print(0xffn & 0x0fn, (-1n) & 0x1234n, (-5n) & (-3n));
print(0xf0n | 0x0fn, (-2n) | 1n, (-5n) | (-3n));
print(0xffn ^ 0x0fn, (-1n) ^ 0xffn, (-5n) ^ (-3n));
print(1n << 100n, 100n << -2n, (-100n) >> 2n, (-1n) >> 100n, (-5n) << -1n, 5n >> -2n);

// >>> TypeError, +1n TypeError, mixed Number/BigInt TypeError
for (const fn of [
  () => 1n >>> 1n,
  () => +1n,
  () => 1n + 1,
  () => 1 - 1n,
  () => 2n * 3,
  () => 4n / 2,
  () => 5n % 2,
  () => 2n ** 3,
  () => 1n & 1,
  () => 1n | 1,
  () => 1n ^ 1,
  () => 1n << 1,
  () => 1n >> 1,
]) {
  try { fn(); } catch (e) { print(e.name); }
}

// String concat with + and template literals
print(1n + "a", "a" + -42n, `${123n}`, String(0n), String(-999n));

// Exact relational comparisons vs Number, NaN, ±Infinity, ===
print(9007199254740993n > 9007199254740992);
print(9007199254740993n >= 9007199254740992);
print(9007199254740993n < 9007199254740992);
print(1n < 1.5, 1n > 0.5, -1n < -0.5, -1n > -1.5);
print(1n < NaN, 1n <= NaN, 1n > NaN, 1n >= NaN);
print(1n < Infinity, 1n > -Infinity, (1n << 2000n) < Infinity);
print(1n === 1n, 1n === 1, 1n !== 1, 0n === -0n);
print(10n < "20", 10n < "abc", 10n > "abc");

// ++ / -- on locals and object properties
let x = 10n;
print(x++, x, ++x, x--, x, --x);
const obj = { v: -1n };
print(obj.v++, obj.v, ++obj.v, obj.v--);

// Map / Set value-key equality
const set = new Set([1n, 1n, 2n ** 100n, 2n ** 100n, -0n, 0n, 1]);
print(set.size, set.has(1n), set.has(2n ** 100n), set.has(0n));
const map = new Map([[2n ** 80n, "big"], [1, "num"], [1n, "bi"]]);
print(map.get(2n ** 80n), map.get(1), map.get(1n));

// Object property keys
const o = {};
o[1n] = "one";
o[123456789012345678901234567890n] = "huge";
print(o["1"], o[1], o["123456789012345678901234567890"]);

// JSON.stringify TypeError + custom BigInt.prototype.toJSON
try { JSON.stringify(1n); } catch (e) { print(e.name); }
try { JSON.stringify({ a: 1n }); } catch (e) { print(e.name); }
BigInt.prototype.toJSON = BigInt.prototype.toString;
print(JSON.stringify({ a: 42n, b: [1n, -2n] }));
delete BigInt.prototype.toJSON;

// Symbol.toPrimitive
const custom = { [Symbol.toPrimitive](hint) { return hint === "string" ? "s" : 7n; } };
print(custom + 3n, `${custom}`);
