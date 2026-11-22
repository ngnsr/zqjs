// Loose equality (== / !=) across all ES2025 types
print(null == undefined, undefined == null, null != undefined);
print(null == 0, undefined == 0, null == false, null == "");
print(1 == "1", 0 == "", 0 == "  ", -0 == 0, NaN == NaN, NaN != NaN);
print(true == 1, false == 0, true == "1", false == "0", true == "true");
print(1n == 1, 1n == "1", 0n == false, 0n == -0, 1n == 1.5, 1n == "abc");
print(9007199254740993n == 9007199254740992);
const o1 = { valueOf() { return 42; } };
const o2 = { toString() { return "42"; } };
const o3 = { [Symbol.toPrimitive]() { return 7n; } };
print(o1 == 42, o1 == "42", o2 == 42, o3 == 7, o3 == "7", o1 == o2);
const s = Symbol("s");
print(s == s, s == Symbol("s"), s == "s", ({ [Symbol.toPrimitive]() { return s; } }) == s);
print([] == 0, [] == "", [1] == 1, [1, 2] == "1,2");
