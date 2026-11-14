// Dense arrays: index, length, push, pop, join, truncation, appending at the end.
let a = [10, 20, 30];
print(a.length, a[0], a[2], a[3], a[-1], a['1']);
a[3] = 40; a[a.length] = 50;
print(a, a.length);
print(a.push(60, 70), a.pop(), a.length);
a.length = 2;
print(a, a.length, a.join('-'), a.join(), [].join(), [1].join(', '));
let empty = [];
print(empty.pop(), empty.length);
// Keys and indices of arrays; nested arrays print flattened; null/undefined print empty.
let nested = [1, [2, [3, [4]]], null, undefined, 'x'];
print(nested, nested.length, Object.keys([7, 8, 9]), Array.isArray(nested), Array.isArray({}));
// Arrays can also have named properties (not listed among the elements).
let named = [1, 2]; named.extra = 'e';
print(named, named.extra, Object.keys(named));
// A cycle prints as empty where it recurses.
let cyc = [1, 2]; cyc.push(cyc);
print(cyc);
// delete past the end is a no-op; deleting length is refused.
print(delete named[5], delete named.length, named.length);
