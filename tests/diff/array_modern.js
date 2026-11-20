// Array.prototype ES2019-ES2023 methods (M44, D74).

// reduceRight
print([1, 2, 3, 4].reduceRight((acc, v, i) => acc + ":" + i + "=" + v, "init"));
print([10, 20, 30].reduceRight((acc, v) => acc - v));
try {
  [].reduceRight((a, b) => a + b);
} catch (e) {
  print(e.name);
}

// flat
print(JSON.stringify([1, [2, [3, [4]]]].flat()));
print(JSON.stringify([1, [2, [3, [4]]]].flat(2)));
print(JSON.stringify([1, [2, [3, [4]]]].flat(0)));
print(JSON.stringify([1, [2, [3, [4]]]].flat(-1)));
print(JSON.stringify([1, [2, [3, [4]]]].flat(Infinity)));

// flatMap
print(JSON.stringify([1, 2, 3].flatMap((x, i) => [x, x * 10 + i])));
print(JSON.stringify([1, 2, 3].flatMap((x) => (x === 2 ? [] : x * 2))));

// copyWithin
const cw1 = [1, 2, 3, 4, 5];
print(JSON.stringify(cw1.copyWithin(0, 3)));
const cw2 = [1, 2, 3, 4, 5];
print(JSON.stringify(cw2.copyWithin(2, 0, 4)));
const cw3 = [1, 2, 3, 4, 5];
print(JSON.stringify(cw3.copyWithin(-2, -3, -1)));
const frozen = Object.freeze([1, 2, 3]);
try {
  frozen.copyWithin(0, 1);
} catch (e) {
  print(e.name);
}
print(JSON.stringify(frozen.copyWithin(0, 5))); // count === 0

// ES2023 change-by-copy
const orig = [3, 1, 4, 1, 5];
print(JSON.stringify(orig.toReversed()));
print(JSON.stringify(orig.toSorted()));
print(JSON.stringify(orig.toSorted((a, b) => b - a)));
print(JSON.stringify([3, undefined, 1, 2].toSorted()));
try {
  orig.toSorted(123);
} catch (e) {
  print(e.name);
}
print(JSON.stringify(orig.toSpliced(1, 2, 9, 8, 7)));
print(JSON.stringify(orig.toSpliced(-2, 1)));
print(JSON.stringify(orig.toSpliced(2)));
print(JSON.stringify(orig.with(1, 99)));
print(JSON.stringify(orig.with(-1, 88)));
try {
  orig.with(10, 0);
} catch (e) {
  print(e.name);
}
try {
  orig.with(-10, 0);
} catch (e) {
  print(e.name);
}
print(JSON.stringify(orig));
