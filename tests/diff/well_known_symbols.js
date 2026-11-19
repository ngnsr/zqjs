// Well-known symbols on Symbol
for (const name of ["toPrimitive", "toStringTag", "hasInstance"]) {
  const sym = Symbol[name];
  const d = Object.getOwnPropertyDescriptor(Symbol, name);
  print(name, typeof sym, String(sym), Symbol.keyFor(sym), d.writable, d.enumerable, d.configurable);
}

// Built-in [Symbol.toStringTag] values and descriptors
function* genFn() {}
async function* asyncGenFn() {}
async function asyncFn() {}

const builtIns = [
  ["Map.prototype", Map.prototype],
  ["Set.prototype", Set.prototype],
  ["Promise.prototype", Promise.prototype],
  ["Symbol.prototype", Symbol.prototype],
  ["Math", Math],
  ["JSON", JSON],
  ["GeneratorPrototype", Object.getPrototypeOf(Object.getPrototypeOf(genFn()))],
  ["AsyncGeneratorPrototype", Object.getPrototypeOf(Object.getPrototypeOf(asyncGenFn()))],
  ["GeneratorFunctionPrototype", Object.getPrototypeOf(genFn)],
  ["AsyncGeneratorFunctionPrototype", Object.getPrototypeOf(asyncGenFn)],
  ["AsyncFunctionPrototype", Object.getPrototypeOf(asyncFn)],
];

for (const [label, obj] of builtIns) {
  const d = Object.getOwnPropertyDescriptor(obj, Symbol.toStringTag);
  print(label, d.value, d.writable, d.enumerable, d.configurable);
}

// Object.prototype.toString on primitives, built-ins, and custom tags
const ots = Object.prototype.toString;
print(
  ots.call(undefined),
  ots.call(null),
  ots.call(true),
  ots.call(1),
  ots.call("a"),
  ots.call(Symbol("s")),
  ots.call([]),
  ots.call(() => {}),
  ots.call(new Error("e")),
  ots.call(new TypeError("te")),
  ots.call(/abc/),
  ots.call(new Map()),
  ots.call(new Set()),
  ots.call(Promise.resolve(1)),
  ots.call(genFn()),
  ots.call(asyncGenFn()),
  ots.call(genFn),
  ots.call(asyncGenFn),
  ots.call(asyncFn)
);

// Custom [Symbol.toStringTag] (data, getter, non-string ignored)
class Custom {
  get [Symbol.toStringTag]() {
    return "CustomClass";
  }
}
print(ots.call(new Custom()));
print(ots.call({ [Symbol.toStringTag]: "Plain" }));
print(ots.call({ [Symbol.toStringTag]: 42 }));
print(ots.call({ [Symbol.toStringTag]: null }));
const taggedArr = [1, 2];
taggedArr[Symbol.toStringTag] = "MyArr";
print(ots.call(taggedArr));

// Deleting configurable [Symbol.toStringTag] falls back to Object
delete Map.prototype[Symbol.toStringTag];
print(ots.call(new Map()));

// Symbol.hasInstance on Function.prototype
const fhiDesc = Object.getOwnPropertyDescriptor(Function.prototype, Symbol.hasInstance);
print("fhi:", typeof fhiDesc.value, fhiDesc.writable, fhiDesc.enumerable, fhiDesc.configurable);
print("fhi.call:", Function.prototype[Symbol.hasInstance].call(Array, []), Function.prototype[Symbol.hasInstance].call({}, {}));

// Custom [Symbol.hasInstance] on plain objects, classes, bound functions, inherited
const Even = {
  [Symbol.hasInstance](x) {
    return typeof x === "number" && x % 2 === 0;
  },
};
print(4 instanceof Even, 3 instanceof Even);

class Base {
  static [Symbol.hasInstance](x) {
    return x && x.ok === true;
  }
}
class Sub extends Base {}
print({ ok: true } instanceof Base, { ok: true } instanceof Sub, { ok: false } instanceof Sub);

function Target() {}
Object.defineProperty(Target, Symbol.hasInstance, {
  value(x) { return x === "magic"; },
});
const BoundTarget = Target.bind(null);
print("magic" instanceof BoundTarget, new Target() instanceof BoundTarget);

// Non-callable [Symbol.hasInstance] and non-object RHS throw TypeError
try {
  1 instanceof { [Symbol.hasInstance]: 42 };
} catch (e) {
  print("noncall-hi:", e.name);
}
try {
  1 instanceof 123;
} catch (e) {
  print("nonobj-hi:", e.name);
}
try {
  1 instanceof { [Symbol.hasInstance]() { throw new RangeError("hi-err"); } };
} catch (e) {
  print("throw-hi:", e.name, e.message);
}
