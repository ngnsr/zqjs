// Basic default parameters: missing, explicit undefined, falsy/null
function f(a, b = a + 1, c = () => b) {
  return [a, b, c()];
}
print(f(10).join(","));
print(f(10, undefined).join(","));
print(f(10, null).join(","));
print(f(10, 0).join(","));

// Parameter scope does NOT see body let/const declarations
let x = 1;
function paramScope(a = () => x) {
  let x = 2;
  return a() + ":" + x;
}
print(paramScope());

// Parameter defaults can capture parameters (even ones initialized later)
function captureLater(a = () => b, b = 42) {
  return a();
}
print(captureLater());
print(captureLater(undefined, 99));

// Referring to a later parameter eagerly is a TDZ ReferenceError
function tdzEager(a = b, b = 1) {
  return a;
}
try {
  tdzEager();
  print("unexpected");
} catch (e) {
  print(e.name);
}
try {
  tdzEager(undefined, 2);
  print("unexpected");
} catch (e) {
  print(e.name);
}

function tdzSelf(a = a) {
  return a;
}
try {
  tdzSelf();
  print("unexpected");
} catch (e) {
  print(e.name);
}

// Named function expression: own name is visible in parameter defaults
const named = function self(n, acc = () => self) {
  return acc() === named;
};
print(named(1));

// Arrow functions with pattern, default, and rest parameters
const aObj = ({ a, b = 2 }) => a + b;
const aArr = ([a, b = 10]) => a * b;
const aDef = (a = 1, b = a + 2) => a + b;
const aRest = (...r) => r.join("-");
const aObjDef = ({ a = 1, b = 2 } = {}) => a + b;
print(aObj({ a: 3 }), aArr([5]), aDef(), aRest(7, 8, 9), aObjDef(), aObjDef({ a: 10 }));

// Defaults + destructuring + side-effect order
const order = [];
function step(s, v) {
  order.push(s);
  return v;
}
function complex(a = step("a", 1), { x = step("x", 2) } = step("obj", {}), [y = step("y", 3)] = step("arr", [])) {
  return a + x + y;
}
print(complex(), order.join(","));
