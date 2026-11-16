let s = "Hello, World!";
print(s.charAt(0), s.charAt(7), s.charAt(-1), s.charAt(100), s.charAt(NaN), s.charAt());

let pair = "A\uD83D\uDE00B";
print(pair.length, pair.charAt(0), pair.charAt(1).charCodeAt(0), pair.charAt(2).charCodeAt(0), pair.charAt(3));

print(s.slice(), s.slice(7), s.slice(7, 12), s.slice(-6, -1), s.slice(5, 2), s.slice(undefined, 5));
print(s.slice(-100, 5), s.slice(NaN, Infinity), pair.slice(1, 3) === "\uD83D\uDE00");

print(s.indexOf("o"), s.indexOf("o", 5), s.indexOf("o", -5), s.indexOf("o", 100), s.indexOf("z"));
print("abc".indexOf("", 0), "abc".indexOf("", 2), "abc".indexOf("", 99));
print("x123true_null_undefined".indexOf(123), "x123true_null_undefined".indexOf(true), "x123true_null_undefined".indexOf(null), "x123true_null_undefined".indexOf());
print(pair.indexOf("\uDE00"));

print(s.includes("World"), s.includes("World", 7), s.includes("World", 8), s.includes("World", -10));
print("abc".includes("", 99), "x123false_null_undefined".includes(123), "x123false_null_undefined".includes(false), "x123false_null_undefined".includes(null), "x123false_null_undefined".includes());
print(pair.includes("\uD83D\uDE00"), pair.includes("\uDE00", 2), pair.includes("\uDE00", 3));

print("".toLowerCase(), "".toUpperCase());
print("Hello, ZQJS 123!".toLowerCase(), "Hello, ZQJS 123!".toUpperCase());

let big = "";
for (let i = 0; i < 300; i++) big = big + (i % 2 === 0 ? "a" : "B");
print(big.toLowerCase().slice(0, 6), big.toUpperCase().slice(294));
