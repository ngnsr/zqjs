let m = new Map();
print(m.size, m.get("a"), m.has("a"), m.delete("a"));

m.set("a", 1).set("b", 2).set("a", 10);
print(m.size, m.get("a"), m.get("b"), m.has("a"), m.has("c"));

m.size = 999;
print(m.size);

// SameValueZero: NaN, -0/+0, distinct types, computed string, object identity
m.set(NaN, "nan-val");
print(m.has(0 / 0), m.get(NaN));

m.set(-0, "zero-val");
print(m.has(0), m.get(+0));

m.set(1, "num").set("1", "str").set(true, "bool").set(null, "null").set(undefined, "undef");
print(m.get(1), m.get("1"), m.get(true), m.get(null), m.get(undefined));

let keyPart = "hel";
m.set(keyPart + "lo", 77);
print(m.get("hello"));

let o1 = { id: 1 };
let o2 = { id: 1 };
let fn = function () { return 1; };
m.set(o1, "first").set(o2, "second").set(fn, "fn-val");
print(m.get(o1), m.get(o2), m.get(fn), m.has({ id: 1 }));

print(m.delete(o1), m.has(o1), m.size);
m.clear();
print(m.size, m.has("a"), m.has(NaN), m.has(o2));

// Constructor with array of entries, null, undefined
let m2 = new Map([["x", 10], ["y", 20], ["x", 30]]);
print(m2.size, m2.get("x"), m2.get("y"));
print(new Map(null).size, new Map(undefined).size);
print(new Map().set("k", 42).get("k"));

// Error cases
try { Map(); print("no-throw"); } catch (e) { print(e.name); }
try { new Map(123); print("no-throw"); } catch (e) { print(e.name); }
try { new Map([1]); print("no-throw"); } catch (e) { print(e.name); }
try { new 1(); print("no-throw"); } catch (e) { print(e.name); }
