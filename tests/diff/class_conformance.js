// Regression tests for ECMAScript class conformance (both VM and treewalk engines).

// 1. Nested classes, private brand isolation, shadowing, write-only/double-init accessors
class Outer {
  #outerOnly = 10;
  #shared = "outer";
  static #sOuter = 100;
  static #sShared = "s-outer";

  #outerMethod() { return "outer-only-m"; }
  #m() { return "outer-m"; }

  test(other) {
    class Inner {
      #shared = "inner";
      static #sShared = "s-inner";
      get #writeOnly() { return 1; }
      set #onlySet(v) { this.#shared = "set:" + v; }

      #m() { return "inner-m:" + this.#shared; }

      readFrom(oOuter, oInner) {
        let shadowedFieldThrow = "none";
        try {
          oOuter.#shared;
        } catch (e) {
          shadowedFieldThrow = e.name;
        }
        let shadowedMethodThrow = "none";
        try {
          oOuter.#m();
        } catch (e) {
          shadowedMethodThrow = e.name;
        }
        let shadowedStaticThrow = "none";
        try {
          Outer.#sShared;
        } catch (e) {
          shadowedStaticThrow = e.name;
        }
        return [
          oOuter.#outerOnly,
          shadowedFieldThrow,
          shadowedMethodThrow,
          shadowedStaticThrow,
          oOuter.#outerMethod(),
          oInner.#shared,
          oInner.#m(),
          Outer.#sOuter,
          Inner.#sShared,
          #outerOnly in oOuter,
          #outerOnly in oInner,
          #shared in oOuter,
          #shared in oInner,
        ];
      }

      badWriteOnlyRead() {
        try {
          return this.#onlySet;
        } catch (e) {
          return e.name;
        }
      }
    }

    const inner = new Inner();
    print("nested priv:", JSON.stringify(inner.readFrom(other, inner)));
    print("write-only read:", inner.badWriteOnlyRead());
  }
}
const outInst = new Outer();
outInst.test(outInst);

// Double-init of private accessor getter via return-override
class AccReturnOverride extends class Base { constructor(o) { return o; } } {
  get #x() { return 1; }
  constructor(o) { super(o); }
}
const sharedTarget = {};
new AccReturnOverride(sharedTarget);
try {
  new AccReturnOverride(sharedTarget);
} catch (e) {
  print("double acc:", e.name);
}

// 2. Intercalated class element & ToPropertyKey evaluation order + static ['prototype']
const order = [];
function logKey(tag, val) {
  return {
    toString() {
      order.push(tag);
      return val;
    },
  };
}
let instCount = 0;
class OrderTest {
  [logKey("m1", "a")]() { return "a"; }
  [logKey("if1", "x")] = (instCount++, 11);
  static [logKey("sf1", "S1")] = (order.push("sf1-init:" + instCount), 22);
  static [logKey("sm1", "B")]() { return "B"; }
  [logKey("if2", -0)] = "zero";
  static [1e25] = "big";
  static {
    order.push("static-block:" + this.S1);
  }
}
const oi1 = new OrderTest();
const oi2 = new OrderTest();
print("order:", JSON.stringify(order));
print("num keys:", oi1["0"], oi2[0], OrderTest["1e+25"]);

for (const fn of [
  () => class { static ["prototype"]() {} },
  () => class { static get ["prototype"]() { return 1; } },
  () => class { static ["prototype"] = 1; },
]) {
  try {
    fn();
    print("unexpected static prototype success");
  } catch (e) {
    print("static proto:", e.name);
  }
}

// Class getter/setter pair on same key stays paired
class AccessorPair {
  constructor() { this._v = 0; }
  get prop() { return this._v + 1; }
  set prop(v) { this._v = v * 2; }
  static get sProp() { return 7; }
  static set sProp(v) { this._sv = v; }
}
const ap = new AccessorPair();
ap.prop = 5;
print("pair:", ap.prop, typeof Object.getOwnPropertyDescriptor(AccessorPair.prototype, "prop").get, typeof Object.getOwnPropertyDescriptor(AccessorPair.prototype, "prop").set);
print("static pair:", AccessorPair.sProp, typeof Object.getOwnPropertyDescriptor(AccessorPair, "sProp").set);

// 3. Function.name inference for class, constructor, methods, accessors, fields, static name()
const symMethod = Symbol("myMethod");
const symNamed = Symbol("mySym");
const symEmpty = Symbol();
const anonArr = [class {}, class { constructor() {} }];
const NamedClassExpr = class {};
print("class names:", JSON.stringify(anonArr[0].name), JSON.stringify(anonArr[1].name), NamedClassExpr.name);

class NameTest {
  [symMethod]() {}
  get [symNamed]() { return 1; }
  set [symEmpty](v) {}
  ["fnField"] = () => {};
  [symNamed] = function () {};
  static ["keptField"] = class { static name = "custom"; };
  static #privFieldFn = () => {};
  static #privMethod() {}
  getPrivNames() {
    return [NameTest.#privFieldFn.name, NameTest.#privMethod.name];
  }
}
const nt = new NameTest();
print(
  "method/field names:",
  NameTest.prototype[symMethod].name,
  Object.getOwnPropertyDescriptor(NameTest.prototype, symNamed).get.name,
  JSON.stringify(Object.getOwnPropertyDescriptor(NameTest.prototype, symEmpty).set.name),
  nt.fnField.name,
  nt[symNamed].name,
  NameTest.keptField.name,
  JSON.stringify(nt.getPrivNames())
);
class StaticNameMethod {
  static name() { return "ok"; }
}
print("static name:", typeof StaticNameMethod.name, StaticNameMethod.name(), StaticNameMethod.name.name);

// 4. Class scope immutability, heritage TDZ, static field TDZ, static blocks & arguments
class OuterMut {
  readName() { return OuterMut.name; }
  tryMutate() { OuterMut = 123; }
}
const om = new OuterMut();
OuterMut = 999;
print("rebound outer:", OuterMut, om.readName());
try {
  om.tryMutate();
} catch (e) {
  print("inner const:", e.name);
}

for (const bad of [
  () => { class A extends A {} },
  () => (class B extends B {}),
  () => { class C { static [C] = 1; } },
  () => { class D { [D]() {} } },
]) {
  try {
    bad();
    print("unexpected no-TDZ");
  } catch (e) {
    print("class TDZ:", e.name);
  }
}

class StaticSelfRef {
  static a = StaticSelfRef;
  static {
    this.b = StaticSelfRef;
    ({ m(x = arguments) { this.gotArgs = x.length; } }).m(1, 2, 3);
  }
}
print("static self:", StaticSelfRef.a === StaticSelfRef, StaticSelfRef.b === StaticSelfRef);

// 5. Derived constructor: arrow `this` TDZ, super() BindThisValue ordering, default spread, uncatchable return, field DefineOwnProperty
class DerivedArrowThis extends class { constructor() {} } {
  constructor(callBefore) {
    const getThis = () => this;
    if (callBefore) getThis();
    super();
    this.fromArrow = getThis() === this;
  }
}
try {
  new DerivedArrowThis(true);
} catch (e) {
  print("arrow before super:", e.name);
}
print("arrow after super:", new DerivedArrowThis(false).fromArrow);

const superLog = [];
class SuperOrder extends class { constructor(v) { superLog.push("base:" + v); } } {
  constructor() {
    try {
      super(super());
    } catch (e) {
      superLog.push("caught:" + e.name);
    }
  }
}
new SuperOrder();
print("super order:", JSON.stringify(superLog));

// Derived default constructor forwarding without Array.prototype[Symbol.iterator]
class BaseArgs {
  constructor(a, b, c) { this.sum = a + b + c; }
}
class DerivedDefault extends BaseArgs {}
const origIter = Array.prototype[Symbol.iterator];
let iterCalled = false;
Array.prototype[Symbol.iterator] = function () {
  iterCalled = true;
  return origIter.call(this);
};
const dd = new DerivedDefault(10, 20, 30);
Array.prototype[Symbol.iterator] = origIter;
print("default spread:", dd.sum, iterCalled);

// Uncatchable derived return-override inside constructor's own try/catch (direct + Reflect.construct)
class ReturnPrimTry extends class { constructor() {} } {
  constructor() {
    super();
    try {
      return 42;
    } catch (e) {
      print("SHOULD NOT CATCH PRIM");
    }
  }
}
class ReturnUninitTry extends class { constructor() {} } {
  constructor() {
    try {
      return undefined;
    } catch (e) {
      print("SHOULD NOT CATCH UNINIT");
    }
  }
}
for (const C of [ReturnPrimTry, ReturnUninitTry]) {
  try {
    new C();
  } catch (e) {
    print("direct catch:", e.name);
  }
  try {
    Reflect.construct(C, []);
  } catch (e) {
    print("reflect catch:", e.name);
  }
}

// Public field uses DefineOwnProperty (Proxy defineProperty trap + throws on non-extensible return override)
const proxyTraps = [];
const proxiedObj = new Proxy({}, {
  defineProperty(target, prop, desc) {
    proxyTraps.push(String(prop) + ":" + desc.writable + "," + desc.enumerable + "," + desc.configurable);
    return Reflect.defineProperty(target, prop, desc);
  },
});
class ProxyReturnBase { constructor() { return proxiedObj; } }
class ProxyFieldSub extends ProxyReturnBase {
  fieldA = 1;
  ["fieldB"] = () => 2;
}
new ProxyFieldSub();
print("proxy traps:", JSON.stringify(proxyTraps));

class FrozenReturnBase { constructor() { return Object.preventExtensions({}); } }
class FrozenFieldSub extends FrozenReturnBase { x = 1; }
try {
  new FrozenFieldSub();
} catch (e) {
  print("frozen field:", e.name);
}
