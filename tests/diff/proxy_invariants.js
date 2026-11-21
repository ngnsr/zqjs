// Proxy ECMAScript invariant checks (M46, D76)

function expectTypeError(label, fn) {
  try {
    fn();
    print(label, "DID NOT THROW");
  } catch (e) {
    print(label, e.name);
  }
}

// Non-callable trap
expectTypeError("non-callable trap", () => {
  const p = new Proxy({}, { get: 123 });
  return p.a;
});

// get invariants
const getTarget = {};
Object.defineProperty(getTarget, "ro", { value: 10, writable: false, configurable: false });
Object.defineProperty(getTarget, "acc", { get: undefined, set() {}, configurable: false });
const getP = new Proxy(getTarget, {
  get() { return 999; }
});
expectTypeError("get non-conf non-writ", () => getP.ro);
expectTypeError("get non-conf no-getter", () => getP.acc);

// set invariants
const setP = new Proxy(getTarget, {
  set() { return true; }
});
expectTypeError("set non-conf non-writ", () => Reflect.set(setP, "ro", 20));
expectTypeError("set non-conf no-setter", () => {
  const t = {};
  Object.defineProperty(t, "roAcc", { get() { return 1; }, set: undefined, configurable: false });
  const sp = new Proxy(t, { set() { return true; } });
  return Reflect.set(sp, "roAcc", 2);
});

// has invariants
const hasTarget = { a: 1 };
Object.defineProperty(hasTarget, "fixed", { value: 1, configurable: false });
const hasP = new Proxy(hasTarget, { has() { return false; } });
expectTypeError("has non-conf", () => "fixed" in hasP);
Object.preventExtensions(hasTarget);
expectTypeError("has non-ext", () => "a" in hasP);

// deleteProperty invariants
const delP = new Proxy(hasTarget, { deleteProperty() { return true; } });
expectTypeError("del non-conf", () => Reflect.deleteProperty(delP, "fixed"));
expectTypeError("del non-ext", () => Reflect.deleteProperty(delP, "a"));

// getPrototypeOf invariants
expectTypeError("getProto bad return", () => {
  const p = new Proxy({}, { getPrototypeOf() { return 42; } });
  return Object.getPrototypeOf(p);
});
expectTypeError("getProto non-ext mismatch", () => {
  const t = Object.preventExtensions({});
  const p = new Proxy(t, { getPrototypeOf() { return {}; } });
  return Object.getPrototypeOf(p);
});

// setPrototypeOf invariants
expectTypeError("setProto non-ext mismatch", () => {
  const t = Object.preventExtensions({});
  const p = new Proxy(t, { setPrototypeOf() { return true; } });
  return Reflect.setPrototypeOf(p, {});
});

// isExtensible invariants
expectTypeError("isExtensible mismatch", () => {
  const p = new Proxy({}, { isExtensible() { return false; } });
  return Object.isExtensible(p);
});

// preventExtensions invariants
expectTypeError("preventExtensions while extensible", () => {
  const p = new Proxy({}, { preventExtensions() { return true; } });
  return Reflect.preventExtensions(p);
});

// getOwnPropertyDescriptor invariants
expectTypeError("gopd bad return", () => {
  const p = new Proxy({}, { getOwnPropertyDescriptor() { return 123; } });
  return Object.getOwnPropertyDescriptor(p, "a");
});
expectTypeError("gopd undefined for non-conf", () => {
  const p = new Proxy(hasTarget, { getOwnPropertyDescriptor() { return undefined; } });
  return Object.getOwnPropertyDescriptor(p, "fixed");
});
expectTypeError("gopd non-conf for missing", () => {
  const p = new Proxy({}, {
    getOwnPropertyDescriptor() { return { value: 1, configurable: false }; }
  });
  return Object.getOwnPropertyDescriptor(p, "missing");
});

// defineProperty invariants
expectTypeError("defProp non-ext", () => {
  const t = Object.preventExtensions({});
  const p = new Proxy(t, { defineProperty() { return true; } });
  return Reflect.defineProperty(p, "a", { value: 1 });
});
expectTypeError("defProp non-conf for missing", () => {
  const p = new Proxy({}, { defineProperty() { return true; } });
  return Reflect.defineProperty(p, "a", { value: 1, configurable: false });
});

// ownKeys invariants
expectTypeError("ownKeys duplicate", () => {
  const p = new Proxy({}, { ownKeys() { return ["a", "a"]; } });
  return Reflect.ownKeys(p);
});
expectTypeError("ownKeys bad key type", () => {
  const p = new Proxy({}, { ownKeys() { return [123]; } });
  return Reflect.ownKeys(p);
});
expectTypeError("ownKeys missing non-conf", () => {
  const p = new Proxy(hasTarget, { ownKeys() { return ["a"]; } });
  return Reflect.ownKeys(p);
});
expectTypeError("ownKeys extra on non-ext", () => {
  const p = new Proxy(hasTarget, { ownKeys() { return ["a", "fixed", "extra"]; } });
  return Reflect.ownKeys(p);
});

// construct invariants
expectTypeError("construct non-object return", () => {
  const p = new Proxy(function () {}, { construct() { return 42; } });
  return new p();
});
expectTypeError("construct on non-constructable", () => {
  const p = new Proxy(() => {}, {});
  return new p();
});
expectTypeError("apply on non-callable", () => {
  const p = new Proxy({}, {});
  return p();
});
