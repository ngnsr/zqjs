// Objects to primitives through the built-in toString/valueOf/join.
print({}, [], [1, 2], [[1, 2], [3]], [null, undefined, 0], [{}]);
print([] + [], [] + {}, {} + 'x', [1] + 1, [1, 2] + 1, [5] * 2, +[], +[7], +[1, 2], +{});
print([2] > 1, [10] < [9], 'a' < ['b'], [1] === [1], ({}).toString(), [].toString());
// Keys: objects convert to strings too.
let o = {};
o[[1, 2]] = 'array key';
o[{}] = 'object key';
print(Object.keys(o), o['1,2']);
