// JSON.parse reviver and JSON.stringify replacer + space (M44, D74).

// 1. JSON.parse with reviver
const parsed1 = JSON.parse('{"a":1,"b":2,"c":{"d":3,"e":4},"arr":[10,20,30]}', (k, v) => {
  if (k === "b") return undefined;
  if (typeof v === "number") return v * 2;
  return v;
});
print(JSON.stringify(parsed1));
print("b" in parsed1);

// Root reviver returning undefined
print(JSON.parse('{"x":1}', () => undefined));

// 2. JSON.stringify with callable replacer + toJSON interaction
const obj = {
  a: 1,
  b: "skip",
  c: {
    toJSON(k) {
      return { inner: k + "!" };
    }
  },
  d: [1, 2, 3]
};
print(JSON.stringify(obj, (k, v) => {
  if (k === "b") return undefined;
  if (typeof v === "number") return v + 10;
  return v;
}));

// Root replacer
print(JSON.stringify({ x: 1 }, (k, v) => (k === "" ? { wrapped: v } : v)));

// 3. JSON.stringify with array replacer (deduplicated, allowlist order, arrays unaffected)
const obj2 = { b: 2, a: 1, c: 3, "42": "numkey", arr: [1, 2] };
print(JSON.stringify(obj2, ["c", "a", 42, "a", 42, "arr"]));
print(JSON.stringify({ a: 1, b: { a: 2, c: 3 } }, ["b", "a"]));
print(JSON.stringify({ a: 1 }, []));

// 4. JSON.stringify with space (number, string, empty objects/arrays)
const nested = { a: 1, b: [true, false, null, {}], c: { d: [] }, empty: {} };
print(JSON.stringify(nested, null, 2));
print(JSON.stringify(nested, null, 12));
print(JSON.stringify(nested, null, -3));
print(JSON.stringify(nested, null, "\t"));
print(JSON.stringify(nested, null, "0123456789ABCDEF"));
