// Root toJSON receives ""
const root = {
  toJSON(key) {
    print("root key:", JSON.stringify(key));
    return { a: 1, b: { toJSON(k) { print("b key:", k); return 2; } } };
  },
};
print(JSON.stringify(root));

// Array elements receive stringified index keys
const arr = [
  { toJSON(k) { return "e" + k; } },
  { toJSON(k) { return undefined; } },
  { toJSON(k) { return [k, 10]; } },
];
print(JSON.stringify(arr));

// Object properties (named and index-like) receive property key
const obj = {
  0: { toJSON(k) { return "idx:" + k; } },
  foo: { toJSON(k) { return "prop:" + k; } },
  omit: { toJSON() { return undefined; } },
  fn: { toJSON() { return () => {}; } },
};
print(JSON.stringify(obj));

// Inherited toJSON
const proto = { toJSON(k) { return { fromProto: this.x, key: k }; } };
const child = Object.create(proto);
child.x = 7;
print(JSON.stringify({ c: child }));

// Getter toJSON and non-callable toJSON ignored
const withGetter = {
  get toJSON() {
    return function (k) { return "getter:" + k; };
  },
};
const nonCallable = { toJSON: 123, ok: true };
print(JSON.stringify({ g: withGetter, n: nonCallable }));

// Returning an object with its own toJSON does NOT invoke toJSON again on the returned value,
// but DOES invoke toJSON on its nested properties.
const nestedReturn = {
  toJSON() {
    return {
      toJSON() { return "should-not-run"; },
      inner: { toJSON(k) { return "inner:" + k; } },
    };
  },
};
print(JSON.stringify(nestedReturn));

// Throwing toJSON propagates
try {
  JSON.stringify({ bad: { toJSON() { throw new TypeError("json-boom"); } } });
} catch (e) {
  print("err:", e.name, e.message);
}

// Array mutation during toJSON
const mut = [
  { toJSON() { mut.length = 1; return "first"; } },
  "second",
];
print(JSON.stringify(mut));

// Cycle detection with toJSON
const cyc = {};
cyc.self = cyc;
try {
  JSON.stringify({ toJSON() { return cyc; } });
} catch (e) {
  print("cyc:", e.name);
}
