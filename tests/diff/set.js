let s = new Set();
print(s.size, s.has(1), s.delete(1));

s.add(1).add(2).add(1);
print(s.size, s.has(1), s.has(2), s.has(3));

s.size = 999;
print(s.size);

// SameValueZero: NaN, +0/-0, equal strings from different allocations, distinct objects
s.add(NaN);
let beforeNanSize = s.size;
s.add(0 / 0);
print(s.has(NaN), s.has(0 / 0), s.size === beforeNanSize);

s.add(-0);
let beforeZeroSize = s.size;
s.add(+0);
print(s.has(0), s.has(-0), s.size === beforeZeroSize);

let part = "hel";
s.add(part + "lo");
print(s.has("hello"), s.has("he" + "llo"));

let o1 = { a: 1 };
let o2 = { a: 1 };
let fn = function () { return 1; };
s.add(o1).add(fn);
print(s.has(o1), s.has(o2), s.has({ a: 1 }), s.has(fn));

s.add("1").add(null).add(undefined).add(true);
print(s.has(1), s.has("1"), s.has(null), s.has(undefined), s.has(true));

print(s.delete(o1), s.has(o1), s.delete(o1));
s.clear();
print(s.size, s.has(1), s.has(NaN), s.has("hello"), s.has(fn));

// Constructor with array, null, undefined
let s2 = new Set([10, 20, 10, 30]);
print(s2.size, s2.has(10), s2.has(20), s2.has(30));
print(new Set(null).size, new Set(undefined).size);
print(new Set().add("k").has("k"));

// Error cases
try { Set(); print("no-throw"); } catch (e) { print(e.name); }
try { new Set(123); print("no-throw"); } catch (e) { print(e.name); }
