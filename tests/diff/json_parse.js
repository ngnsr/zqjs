// Primitives and whitespace
print(JSON.parse("null"), JSON.parse("true"), JSON.parse("false"));
print(JSON.parse(" \t\r\n 42 \n\t\r "));
print(JSON.parse("-0") === 0, 1 / JSON.parse("-0") === -Infinity);
print(JSON.parse("0"), JSON.parse("-123"), JSON.parse("3.14159"), JSON.parse("1e20"), JSON.parse("1e21"));
print(JSON.parse("1e-6"), JSON.parse("1e-7"), JSON.parse("1.5E+2"), JSON.parse("-2.5e-3"));
print(JSON.parse("1e500") === Infinity, JSON.parse("-1e500") === -Infinity);

// Strings, escapes, surrogate pairs, lone surrogates
print(JSON.parse('""').length, JSON.parse('"hello"'));
print(JSON.parse('"\\"\\\\\\/"'));
const ctrl = JSON.parse('"\\b\\f\\n\\r\\t"');
print(ctrl.length, ctrl.charCodeAt(0), ctrl.charCodeAt(1), ctrl.charCodeAt(2), ctrl.charCodeAt(3), ctrl.charCodeAt(4));
print(JSON.parse('"\\u0041\\u0061"'));
const pair = JSON.parse('"\\uD83D\\uDE00"');
print(pair.length, pair.charCodeAt(0), pair.charCodeAt(1));
const lone = JSON.parse('"\\uD800-\\uDC00"');
print(lone.length, lone.charCodeAt(0), lone.charCodeAt(1), lone.charCodeAt(2));

// Arrays and objects
const arr = JSON.parse('[1, "two", true, null, [3, 4], {"k": 5}]');
print(Array.isArray(arr), arr.length, arr[0], arr[1], arr[4][1], arr[5].k);
print(JSON.parse("[]").length, Object.keys(JSON.parse("{}")).length);

const obj = JSON.parse('{"a": 1, "b": {"c": [true, false]}, "a": 2}');
print(obj.a, obj.b.c[0], obj.b.c[1], Object.keys(obj));

// __proto__ is an own data property, not prototype mutation
const protoObj = JSON.parse('{"__proto__": 42, "x": 1}');
print(Object.getPrototypeOf(protoObj) === Object.getPrototypeOf({}), protoObj.__proto__, protoObj.x);

// Numeric keys preserve index semantics
const idxObj = JSON.parse('{"2": "b", "0": "a", "x": 3, "1": "c"}');
print(Object.keys(idxObj), idxObj[0], idxObj["1"], idxObj[2], idxObj.x);

// Non-callable reviver arguments are ignored per spec
print(JSON.parse("123", null), JSON.parse("456", undefined), JSON.parse("789", 42), JSON.parse("[1,2]", {}).length);

// Input ToString coercion
print(JSON.parse(123), JSON.parse(true), JSON.parse(null));

// SyntaxError cases (catchable)
const bad = [
  "",
  "   ",
  "undefined",
  "NaN",
  "Infinity",
  "[1,]",
  '{"a":1,}',
  "{a:1}",
  "'a'",
  "1 2",
  "{} []",
  "01",
  "-01",
  "+1",
  ".5",
  "1.",
  "1e",
  "1e+",
  "-",
  "-.",
  '"\n"',
  '"\t"',
  '"\\a"',
  '"\\u12"',
  '"\\u123g"',
  '"unterminated',
  "\v1",
  "\f1",
  "\u00A01",
  "\uFEFF1",
];
for (let i = 0; i < bad.length; i++) {
  let caught = "none";
  try {
    JSON.parse(bad[i]);
  } catch (e) {
    caught = e.name;
  }
  if (caught !== "SyntaxError") print("FAIL", i, caught);
}
try {
  JSON.parse();
} catch (e) {
  print("noarg", e.name);
}
print("done");
