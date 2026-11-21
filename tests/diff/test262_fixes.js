// M49 (D79): Node-differential regression tests for Test262 conformance fixes.

// 1. Array.from array-like fallback
print(JSON.stringify(Array.from({ length: 3 })));
print(JSON.stringify(Array.from({ length: 3, 0: "a", 2: "c" }, (v, i) => `${i}:${v}`)));

// 2. Function.prototype.apply with function argArray & null/undefined
function fApply(a, b) { return [typeof this, this.x, a, b]; }
const recv = { x: 42 };
print(JSON.stringify(fApply.apply(recv, null)));
print(JSON.stringify(fApply.apply(recv, Array)));

// 3. Built-in .length, Number.prototype, Object.*, Array.*
print(Object.length, Array.length, String.length, Number.length);
print(Object.keys.length, Object.create.length, Object.getPrototypeOf.length, Array.isArray.length);
print(Math.min.length, Math.max.length);
print("abc".charAt.length, "abc".charCodeAt.length, "abc".includes.length, "abc".indexOf.length, "abc".lastIndexOf.length, "abc".search.length);
print(Number.prototype.hasOwnProperty("constructor"), Number.prototype.hasOwnProperty("toString"), Number.prototype.hasOwnProperty("valueOf"));
print(Object.prototype.toString.call(Number.prototype), (255).toString(16));
print(Array.isArray(Array.prototype));
print(Object.prototype.isPrototypeOf.call(null, 1), Object.prototype.isPrototypeOf.call(undefined, "x"));

try {
  Object.create({}, "abc");
} catch (e) {
  print(e.name);
}

try {
  Object.defineProperty([], "length", { value: -1, configurable: true });
} catch (e) {
  print(e.name);
}

try {
  const p = new Proxy({}, { preventExtensions() { return false; } });
  Object.freeze(p);
} catch (e) {
  print(e.name);
}

// 4. TypedArray.from with subclass & custom constructor
class SubU8 extends Uint8Array {}
const sub = SubU8.from([1, 2, 3], x => x * 10);
print(sub instanceof SubU8, sub instanceof Uint8Array, sub.length, sub[0], sub[1], sub[2]);

// 5. RegExp named capture groups with Unicode & escapes
const re1 = /(?<\u03C0>a)/;
print(re1.exec("bab").groups["\u03C0"], re1.exec("bab").groups.\u03C0);
const re2 = new RegExp("(?<\\u0041>.)");
print(re2.test("x"), re2.exec("x").groups.A);

// 6. Escaped keywords as class method names
class EscapedMethods {
  br\u0065ak() { return "brk"; }
  ca\u0073e() { return "cs"; }
}
const em = new EscapedMethods();
print(em.break(), em.case());

// 7. super[expr] before super() checks uninitialized this first
class Base {
  constructor() { throw new Error("base"); }
}
class DerivedGet extends Base {
  constructor() { return super[super()]; }
}
class DerivedSet extends Base {
  constructor() { super[super()] = 1; }
}
for (const C of [DerivedGet, DerivedSet]) {
  try {
    new C();
  } catch (e) {
    print(e.name);
  }
}

// 8. Promise combinators: resolve lookup before iterator, iteratorClose ordering
{
  let closed = 0;
  const iter = {
    [Symbol.iterator]() {
      return {
        next() { return { value: 1, done: false }; },
        return() { closed++; return {}; },
      };
    },
  };
  const BadCtor = function(exec) { return new Promise((res, rej) => exec(res, rej)); };
  Object.defineProperty(BadCtor, "resolve", { get() { throw new TypeError("no resolve"); } });
  Promise.any.call(BadCtor, iter).catch(e => {
    print("bad_resolve", e.name, closed);
  });
}
