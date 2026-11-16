// Primitives and top-level non-serializable values
print(JSON.stringify(null), JSON.stringify(true), JSON.stringify(false));
print(JSON.stringify(0), JSON.stringify(-0), JSON.stringify(42), JSON.stringify(-3.14));
print(JSON.stringify(NaN), JSON.stringify(Infinity), JSON.stringify(-Infinity));
print(JSON.stringify(), JSON.stringify(undefined), JSON.stringify(function () {}));

// Number formatting edge cases
print(JSON.stringify(1e+21));
print(JSON.stringify(1e-7));
print(JSON.stringify(1e-6));
print(JSON.stringify(1e20));
print(JSON.stringify(1.7976931348623157e+308));
print(JSON.stringify(5e-324));

// Strings, control characters, surrogate pairs, lone surrogates
print(JSON.stringify(""));
print(JSON.stringify('a"b\\c\b\f\n\r\t'));
print(JSON.stringify("\x00\x07\x0b\x1f"));
print(JSON.stringify("\uD83D\uDE00"));
print(JSON.stringify("\uD800"));
print(JSON.stringify("\uDC00"));
print(JSON.stringify("\uD800\uD800"));

// Arrays and objects: undefined/function handling, property order, Map/Set
print(JSON.stringify([1, undefined, function () {}, NaN, Infinity, "x"]));
print(JSON.stringify({ a: 1, b: undefined, c: function () {}, d: null, e: "ok" }));
print(JSON.stringify({ "2": "b", "0": "a", z: 3, "1": "c", a: 4 }));
print(JSON.stringify(new Map([["a", 1]])), JSON.stringify(new Set([1, 2])));

// Non-callable toJSON and non-callable/non-array replacer are ignored
print(JSON.stringify({ toJSON: 123, a: 1 }));
print(JSON.stringify({ a: 1 }, null), JSON.stringify({ a: 1 }, undefined), JSON.stringify({ a: 1 }, 42), JSON.stringify({ a: 1 }, {}));

// Shared references in DAG serialize normally
const shared = { x: 1 };
print(JSON.stringify([shared, shared]), JSON.stringify({ a: shared, b: shared }));

// Circular references throw TypeError
const cycObj = { a: 1 };
cycObj.self = cycObj;
try {
  JSON.stringify(cycObj);
} catch (e) {
  print("cycObj", e.name);
}

const cycArr = [1];
cycArr.push(cycArr);
try {
  JSON.stringify(cycArr);
} catch (e) {
  print("cycArr", e.name);
}

const a = {};
const b = { a: a };
a.b = b;
try {
  JSON.stringify(a);
} catch (e) {
  print("indirect", e.name);
}

// Round-trip
const round = JSON.parse(JSON.stringify({ n: [1, -0, true, null, "hi\n\"\\"], k: { ok: false } }));
print(round.n[0], 1 / round.n[1] === Infinity, round.n[2], round.n[3], round.n[4], round.k.ok);
