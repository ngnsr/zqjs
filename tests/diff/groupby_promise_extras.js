// Object.groupBy, Map.groupBy, Promise.withResolvers, Promise.try (M44, D74).

// Object.groupBy
const items = [
  { name: "a", cat: "x" },
  { name: "b", cat: "y" },
  { name: "c", cat: "x" },
];
const groupedObj = Object.groupBy(items, (it, idx) => it.cat + "_" + (idx % 2));
print(Object.getPrototypeOf(groupedObj));
print(JSON.stringify(groupedObj));

// Map.groupBy
const k1 = { id: 1 };
const k2 = { id: 2 };
const groupedMap = Map.groupBy([1, 2, 3, 4], (n) => (n % 2 === 0 ? k1 : k2));
print(groupedMap instanceof Map);
print(JSON.stringify(groupedMap.get(k1)));
print(JSON.stringify(groupedMap.get(k2)));

// IteratorClose when callback throws
let closedCount = 0;
const customIter = {
  [Symbol.iterator]() {
    let i = 0;
    return {
      next() { return { value: i++, done: false }; },
      return() { closedCount++; return { done: true }; }
    };
  }
};
try {
  Object.groupBy(customIter, () => { throw new Error("boom1"); });
} catch (e) {
  print(e.message, closedCount);
}
try {
  Map.groupBy(customIter, () => { throw new Error("boom2"); });
} catch (e) {
  print(e.message, closedCount);
}

// Promise.withResolvers & Promise.try
const wr1 = Promise.withResolvers();
wr1.resolve(42);
wr1.promise.then((v) => print("wr1:", v));

const wr2 = Promise.withResolvers();
wr2.reject("err2");
wr2.promise.catch((e) => print("wr2:", e));

Promise.try((a, b) => a + b, 10, 20).then((v) => print("try1:", v));
Promise.try(() => { throw new TypeError("try-boom"); }).catch((e) => print("try2:", e.name, e.message));
Promise.try(123).catch((e) => print("try3:", e.name));
