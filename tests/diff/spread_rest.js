// Spread in array literals (any iterable)
const s = new Set([2, 3]);
const m = new Map([["a", 1], ["b", 2]]);
print([1, ...s, 4, ..."hi", ...m.keys()].join(","));
print([..."A\uD83D\uDE00B"].map(c => c.length).join(","));

// Spread in calls (regular, method preserving `this`, optional call)
function sum4(a, b, c, d) {
  return a + b + c + d;
}
print(sum4(...[1, 2], ...new Set([3, 4])));

const obj = {
  base: 100,
  add(x, y, z) {
    return this.base + x + y + z;
  },
};
print(obj.add(1, ...[2, 3]));
print(obj.add?.(...[4, 5], 6));
const nil = null;
print(nil?.add(...[1, 2]));

// Spread in `new` for built-in constructors
const setFromSpread = new Set(...[[10, 20, 10]]);
print(setFromSpread.size, setFromSpread.has(20));
const mapFromSpread = new Map(...[[["x", 1], ["y", 2]]]);
print(mapFromSpread.size, mapFromSpread.get("y"));

// Object spread: order, overwrite, null/undefined/primitives
const o1 = { a: 1, b: 2 };
const o2 = { b: 20, c: 3 };
const merged = { ...o1, b: 10, ...o2, d: 4, ...null, ...undefined, ...42, ..."xy" };
print(Object.keys(merged).join(","));
print(merged.a, merged.b, merged.c, merged.d, merged[0], merged[1]);

// Rest parameters in functions and arrows + closures + destructured rest
function collect(first, ...rest) {
  return () => first + ":" + rest.join(",");
}
const c1 = collect("head", 1, 2, 3);
const c2 = collect("only");
print(c1(), c2());

const arrowRest = (...xs) => xs.reduce((a, b) => a + b, 0);
print(arrowRest(1, 2, 3, 4));

const destructRest = (...[head, ...tail]) => head + "|" + tail.join(",");
print(destructRest(10, 20, 30));

// Large array spread and destructuring
const big = [];
for (let i = 0; i < 200; i++) big.push(i);
const bigCopy = [...big];
const [b0, b1, ...bigTail] = bigCopy;
print(bigCopy.length, b0, b1, bigTail.length, bigTail[197]);
