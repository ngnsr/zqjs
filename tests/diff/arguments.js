// Basic arguments access, length, extra & fewer args
function sum() {
  let total = 0;
  for (let i = 0; i < arguments.length; i++) {
    total += arguments[i];
  }
  return total;
}
print(sum(), sum(1, 2, 3, 4));

function withParams(a, b) {
  return [a, b, arguments.length, arguments[0], arguments[2]].join(",");
}
print(withParams(10), withParams(10, 20, 30));

// Tag, iterator, spread, for-of, Array.from, Object.keys, descriptor
function inspect() {
  print(Object.prototype.toString.call(arguments));
  print(arguments[Symbol.iterator] === Array.prototype.values);
  print([...arguments].join("-"));
  let out = [];
  for (const x of arguments) out.push(x);
  print(out.join("|"));
  print(Array.from(arguments).join(":"));
  print(Object.keys(arguments).join(","));
  const d = Object.getOwnPropertyDescriptor(arguments, "length");
  print(d.value, d.writable, d.enumerable, d.configurable);
}
inspect("a", "b", "c");

// Arrow functions lexically inherit arguments (even when returned as a closure)
function makeReader() {
  const inner = () => () => [arguments.length, arguments[0], arguments[1]].join("/");
  return inner();
}
const reader = makeReader("hello", "world");
print(reader());

// arguments in parameter default
function defArg(x = arguments.length) {
  return x;
}
print(defArg(), defArg(undefined, 99), defArg(7, 99));

// Class constructor & method arguments
class C {
  constructor() {
    this.n = arguments.length;
  }
  getArgs() {
    return [...arguments].join("+");
  }
}
const c = new C(1, 2, 3);
print(c.n, c.getArgs("x", "y"));

// Shadowing arguments with param or let
function shadowParam(arguments) {
  return arguments;
}
print(shadowParam(123));

function shadowLet() {
  let arguments = 456;
  return arguments;
}
print(shadowLet(1, 2, 3));

// Passing arguments to Function.prototype.apply
function add3(a, b, c) {
  return a + b + c;
}
function forward() {
  return add3.apply(null, arguments);
}
print(forward(10, 20, 30));
