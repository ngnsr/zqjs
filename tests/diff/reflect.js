// Reflect namespace tests (M46, D76)

print("tag:", Object.prototype.toString.call(Reflect), Reflect[Symbol.toStringTag]);
print("typeof:", typeof Reflect);

// Non-object target TypeErrors
for (const method of [
  "get", "set", "has", "deleteProperty", "ownKeys",
  "getOwnPropertyDescriptor", "defineProperty",
  "getPrototypeOf", "setPrototypeOf", "isExtensible", "preventExtensions"
]) {
  try {
    Reflect[method](42, "a");
    print(method, "no-throw!");
  } catch (e) {
    print(method, "non-obj:", e.name);
  }
}
try { Reflect.apply(123, null, []); } catch (e) { print("apply non-fn:", e.name); }
try { Reflect.construct(() => {}, []); } catch (e) { print("construct arrow:", e.name); }
try { Reflect.construct(function () {}, [], () => {}); } catch (e) { print("construct bad newTarget:", e.name); }

// 1. Reflect.get & receiver forwarding
const proto = {
  _x: 10,
  get x() { return this._x + 1; },
};
const obj = Object.create(proto);
obj._x = 20;
print("get:", Reflect.get(obj, "x"), Reflect.get(obj, "x", { _x: 99 }), Reflect.get(obj, "missing"));

// 2. Reflect.set & receiver forwarding
const target = { a: 1 };
const receiver = {};
print("set:", Reflect.set(target, "a", 2), target.a);
print("set with receiver:", Reflect.set(target, "b", 3, receiver), target.b, receiver.b);

let setThis = null;
const accTarget = {
  set val(v) { setThis = this; this._v = v; }
};
const rcv2 = {};
print("set accessor:", Reflect.set(accTarget, "val", 77, rcv2), setThis === rcv2, rcv2._v, accTarget._v);

Object.defineProperty(target, "ro", { value: 5, writable: false, configurable: true });
print("set readonly:", Reflect.set(target, "ro", 9), target.ro);
Object.preventExtensions(target);
print("set non-ext:", Reflect.set(target, "newProp", 1), "newProp" in target);

// 3. Reflect.has
print("has:", Reflect.has(obj, "x"), Reflect.has(obj, "_x"), Reflect.has(obj, "nope"));

// 4. Reflect.deleteProperty
const delObj = { a: 1 };
Object.defineProperty(delObj, "fixed", { value: 2, configurable: false });
print("del:", Reflect.deleteProperty(delObj, "a"), "a" in delObj, Reflect.deleteProperty(delObj, "fixed"), delObj.fixed);

// 5. Reflect.ownKeys
const s1 = Symbol("s1");
const s2 = Symbol("s2");
const okObj = { b: 1, 2: "two", 0: "zero", a: 2, [s1]: "sym1" };
Object.defineProperty(okObj, "hidden", { value: 9, enumerable: false });
Object.defineProperty(okObj, s2, { value: "sym2", enumerable: false });
print("ownKeys:", Reflect.ownKeys(okObj).map(k => typeof k === "symbol" ? k.toString() : k).join(","));

const arr = [10, 20];
arr.extra = "hi";
print("ownKeys arr:", Reflect.ownKeys(arr).join(","));

// 6. Reflect.getOwnPropertyDescriptor
const d1 = Reflect.getOwnPropertyDescriptor(okObj, "hidden");
print("desc:", d1.value, d1.enumerable, d1.writable, d1.configurable);
print("desc missing:", Reflect.getOwnPropertyDescriptor(okObj, "missing"));

// 7. Reflect.defineProperty
const defObj = {};
print("def1:", Reflect.defineProperty(defObj, "p", { value: 42, writable: false, configurable: false }));
print("def2 reject:", Reflect.defineProperty(defObj, "p", { value: 43 }), defObj.p);
Object.preventExtensions(defObj);
print("def3 non-ext:", Reflect.defineProperty(defObj, "q", { value: 1 }), "q" in defObj);

// 8 & 9. Reflect.getPrototypeOf & Reflect.setPrototypeOf
const pA = { tag: "A" };
const pB = { tag: "B" };
const inst = Object.create(pA);
print("getProto:", Reflect.getPrototypeOf(inst) === pA, Reflect.getPrototypeOf(Object.create(null)));
print("setProto:", Reflect.setPrototypeOf(inst, pB), inst.tag, Reflect.getPrototypeOf(inst) === pB);
print("setProto cycle:", Reflect.setPrototypeOf(inst, inst));
Object.preventExtensions(inst);
print("setProto non-ext same:", Reflect.setPrototypeOf(inst, pB));
print("setProto non-ext diff:", Reflect.setPrototypeOf(inst, pA));

// 10 & 11. Reflect.isExtensible & Reflect.preventExtensions
const extObj = { a: 1 };
print("ext:", Reflect.isExtensible(extObj), Reflect.preventExtensions(extObj), Reflect.isExtensible(extObj));

// 12. Reflect.apply
function add(a, b) { return this.base + a + b; }
print("apply:", Reflect.apply(add, { base: 100 }, [20, 3]));
print("apply array-like:", Reflect.apply(add, { base: 1 }, { length: 2, 0: 4, 1: 5 }));

// 13. Reflect.construct
class Base {
  constructor(x) { this.x = x; }
  kind() { return "Base"; }
}
class Sub extends Base {
  kind() { return "Sub"; }
}
const c1 = Reflect.construct(Base, [55]);
const c2 = Reflect.construct(Base, [66], Sub);
print("construct:", c1.x, c1 instanceof Base, c1.kind());
print("construct newTarget:", c2.x, c2 instanceof Sub, c2 instanceof Base, c2.kind());

class Derived extends Base {
  constructor(x, y) {
    super(x);
    this.y = y;
  }
}
const c3 = Reflect.construct(Derived, [7, 8]);
print("construct derived:", c3.x, c3.y, c3 instanceof Derived);
