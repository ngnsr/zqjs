function show(v) {
  if (v === undefined) return 'undefined';
  return JSON.stringify(v);
}

// find, findIndex, findLast, findLastIndex, some, every
let arr = [10, 20, 30, 20, 40];
print(arr.find((x) => x > 15), arr.find((x) => x > 100));
print(arr.findIndex((x) => x === 20), arr.findIndex((x) => x === 99));
print(arr.findLast((x) => x < 35), arr.findLast((x) => x < 0));
print(arr.findLastIndex((x) => x === 20), arr.findLastIndex((x) => x === 99));
print(arr.some((x) => x === 30), arr.some((x) => x === 99), [].some(() => true));
print(arr.every((x) => x >= 10), arr.every((x) => x < 30), [].every(() => false));

// thisArg & initial length capture
let box = { min: 25 };
print(arr.find(function (x) { return x > this.min; }, box));
print(arr.some(function (x) { return x > this.min; }, box));
print(arr.every(function (x) { return x < this.min; }, box));

let mut = [1, 2, 3, 4];
let seenFind = [];
mut.find((x, i) => {
  seenFind.push([i, x]);
  if (i === 0) mut.pop();
  if (i === 1) mut.push(99);
  return false;
});
print(show(seenFind), show(mut));

// concat
print(show([1, 2].concat([3, 4], 5, [6, [7]])));
print(show([].concat()));

// reverse
let rev = [1, 2, 3, 4];
let revRet = rev.reverse();
print(revRet === rev, show(rev), show([].reverse()));

// at
print(show([10, 20, 30].at(0)), show([10, 20, 30].at(-1)), show([10, 20, 30].at(-4)), show([10, 20, 30].at(3)));

// lastIndexOf
let dup = [1, 2, 3, 2, 1];
print(dup.lastIndexOf(2), dup.lastIndexOf(2, 2), dup.lastIndexOf(2, -3), dup.lastIndexOf(2, -10));
print(dup.lastIndexOf(2, undefined), [NaN].lastIndexOf(NaN), [].lastIndexOf(1));

// fill
print(show([1, 2, 3, 4].fill(0, 1, 3)));
print(show([1, 2, 3, 4].fill(9, -2)));
print(show([1, 2, 3].fill(7, NaN, Infinity)));

// shift & unshift
let q = [1, 2, 3];
print(q.shift(), show(q), [].shift());
print(q.unshift(10, 20), show(q), q.unshift(), show(q));

// splice
let s1 = [1, 2, 3, 4, 5];
print(show(s1.splice(1, 2, 9, 8, 7)), show(s1));
let s2 = [1, 2, 3, 4, 5];
print(show(s2.splice(-2)), show(s2));
let s3 = [1, 2, 3];
print(show(s3.splice(1, 5)), show(s3));
let s4 = [1, 2, 3];
print(show(s4.splice()), show(s4));
let s5 = [1, 2, 3];
print(show(s5.splice(1, -2, 99)), show(s5));

// sort: default, undefined last, stability, comparator edge cases, throwing comparator
let def = [10, 2, undefined, 1, 'b', 'a', undefined, 20];
let defRet = def.sort();
print(defRet === def, show(def.map((x) => {
  if (x === undefined) return 'undef';
  return String(x);
})));

let pairs = [
  { k: 1, v: 'a' },
  { k: 2, v: 'b' },
  { k: 1, v: 'c' },
  { k: 2, v: 'd' },
  { k: 1, v: 'e' },
];
pairs.sort((a, b) => a.k - b.k);
print(show(pairs));

// comparator returning NaN / non-numbers
let nanArr = [3, 1, 2];
nanArr.sort(() => NaN);
print(show(nanArr));
let strCmp = [3, 1, 2];
strCmp.sort((a, b) => String(a - b));
print(show(strCmp));

// comparator that throws leaves array unchanged
let throwArr = [3, 1, 2];
try {
  throwArr.sort((a, b) => {
    if (a === 1 || b === 1) throw 'boom';
    return a - b;
  });
} catch (e) {
  print('caught', e, show(throwArr));
}

// comparator that mutates the array
let mutSort = [3, 1, 2, 4];
mutSort.sort((a, b) => {
  if (mutSort.length > 2) mutSort.pop();
  return a - b;
});
print(show(mutSort));
