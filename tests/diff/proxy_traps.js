// Proxy traps, pass-through, prototype receiver, revocable, and built-in integration (M46, D76)

print("Proxy.prototype:", Proxy.prototype);
try { Proxy({}, {}); } catch (e) { print("no-new:", e.name); }
try { new Proxy(1, {}); } catch (e) { print("bad target:", e.name); }
try { new Proxy({}, 1); } catch (e) { print("bad handler:", e.name); }

// 1. Pass-through when traps omitted
const raw = { a: 1, b: 2 };
const pt = new Proxy(raw, {});
print("passthrough get/has:", pt.a, "b" in pt, "c" in pt);
pt.c = 3;
print("passthrough set/del:", raw.c, delete pt.b, "b" in raw);
print("passthrough keys:", Object.keys(pt).join(","));

// 2. get / set / has / deleteProperty traps + prototype receiver
const log = [];
const target = { _v: 10, a: 1 };
const p = new Proxy(target, {
  get(t, k, r) {
    log.push("get:" + String(k) + ":" + (r === child ? "child" : r === p ? "proxy" : "other"));
    return Reflect.get(t, k, r);
  },
  set(t, k, v, r) {
    log.push("set:" + String(k) + ":" + (r === child ? "child" : r === p ? "proxy" : "other"));
    return Reflect.set(t, k, v, r);
  },
  has(t, k) {
    log.push("has:" + String(k));
    return k === "virtual" ? true : Reflect.has(t, k);
  },
  deleteProperty(t, k) {
    log.push("del:" + String(k));
    return Reflect.deleteProperty(t, k);
  },
});

const child = Object.create(p);
print("p.a:", p.a);
print("child.a:", child.a);
print("virtual in child:", "virtual" in child);
p.a = 2;
child.x = 99;
print("child.x:", child.x, "target.x:", target.x);
print("del p.a:", delete p.a, "a" in target);
print("log:", log.join("|"));

// 3. ownKeys + getOwnPropertyDescriptor + defineProperty + Object.keys / for...in / spread / JSON.stringify
const sym = Symbol("sym");
const oTarget = { a: 1, b: 2, [sym]: 3 };
const oProxy = new Proxy(oTarget, {
  ownKeys() {
    return ["b", "virtual", "hidden", sym];
  },
  getOwnPropertyDescriptor(t, k) {
    if (k === "virtual") return { value: 42, enumerable: true, configurable: true, writable: true };
    if (k === "hidden") return { value: 99, enumerable: false, configurable: true, writable: true };
    return Reflect.getOwnPropertyDescriptor(t, k);
  },
  get(t, k, r) {
    if (k === "virtual") return 42;
    return Reflect.get(t, k, r);
  },
  defineProperty(t, k, d) {
    log.push("def:" + String(k) + ":" + d.value);
    return Reflect.defineProperty(t, k, d);
  }
});

print("Object.keys:", Object.keys(oProxy).join(","));
print("Object.getOwnPropertyNames:", Object.getOwnPropertyNames(oProxy).join(","));
print("Object.getOwnPropertySymbols:", Object.getOwnPropertySymbols(oProxy).length);
print("Reflect.ownKeys:", Reflect.ownKeys(oProxy).map(k => typeof k === "symbol" ? "SYM" : k).join(","));
const forInKeys = [];
for (const k in oProxy) forInKeys.push(k);
print("for..in:", forInKeys.join(","));
const spread = { ...oProxy };
print("spread:", spread.b, spread.virtual, spread.hidden, spread[sym]);
print("json:", JSON.stringify(oProxy));
Object.defineProperty(oProxy, "added", { value: 7, enumerable: true, configurable: true, writable: true });
print("added:", oTarget.added);

// 4. getPrototypeOf / setPrototypeOf / isExtensible / preventExtensions
const proto1 = { p: 1 };
const proto2 = { p: 2 };
const mTarget = Object.create(proto1);
const mProxy = new Proxy(mTarget, {
  getPrototypeOf(t) { return Reflect.getPrototypeOf(t); },
  setPrototypeOf(t, np) { return Reflect.setPrototypeOf(t, np); },
  isExtensible(t) { return Reflect.isExtensible(t); },
  preventExtensions(t) { return Reflect.preventExtensions(t); },
});
print("proto:", Object.getPrototypeOf(mProxy) === proto1);
Object.setPrototypeOf(mProxy, proto2);
print("proto2:", Object.getPrototypeOf(mProxy) === proto2, mProxy.p);
print("ext:", Object.isExtensible(mProxy));
Object.preventExtensions(mProxy);
print("ext after:", Object.isExtensible(mProxy), Object.isExtensible(mTarget));

// 5. apply & construct traps + class Sub extends callableProxy
function baseFn(a, b) { return a + b; }
const fnProxy = new Proxy(baseFn, {
  apply(t, thisArg, args) {
    return Reflect.apply(t, thisArg, args) * 10;
  },
  construct(t, args, newTarget) {
    const o = Reflect.construct(t, args, newTarget);
    o.fromTrap = true;
    return o;
  }
});
print("typeof fnProxy:", typeof fnProxy);
print("call fnProxy:", fnProxy(2, 3));
print("call/apply/bind:", fnProxy.call(null, 1, 2), fnProxy.apply(null, [3, 4]), fnProxy.bind(null, 5)(6));

class BaseClass {
  constructor(x) { this.x = x; }
  tag() { return "Base"; }
}
const clsProxy = new Proxy(BaseClass, {
  construct(t, args, newTarget) {
    const o = Reflect.construct(t, [args[0] + 100], newTarget);
    o.proxied = true;
    return o;
  }
});
class Sub extends clsProxy {
  constructor(x) {
    super(x);
    this.sub = true;
  }
}
const subInst = new Sub(5);
print("sub:", subInst.x, subInst.proxied, subInst.sub, subInst instanceof Sub, subInst.tag());

// 6. Array.isArray + JSON.stringify on array proxy
const arrProxy = new Proxy([10, 20, 30], {});
print("isArray:", Array.isArray(arrProxy), Array.isArray(new Proxy(arrProxy, {})), Array.isArray(p));
print("json arr:", JSON.stringify(arrProxy));

// 7. Nested proxies
const inner = new Proxy({ k: 5 }, {
  get(t, k) { return t[k] + 1; }
});
const outer = new Proxy(inner, {
  get(t, k, r) { return Reflect.get(t, k, r) * 2; }
});
print("nested:", outer.k);

// 8. Proxy.revocable + typeof after revoke + Array.isArray after revoke
const rev = Proxy.revocable(function () { return 1; }, {
  get() { return 42; }
});
print("rev before:", typeof rev.proxy, rev.proxy.x, rev.proxy());
rev.revoke();
rev.revoke(); // idempotent
print("rev typeof after:", typeof rev.proxy);
for (const op of [
  () => rev.proxy.x,
  () => { rev.proxy.x = 1; },
  () => "x" in rev.proxy,
  () => delete rev.proxy.x,
  () => rev.proxy(),
  () => new rev.proxy(),
  () => Object.keys(rev.proxy),
  () => Object.getPrototypeOf(rev.proxy),
  () => Array.isArray(rev.proxy),
]) {
  try {
    op();
    print("revoked did not throw!");
  } catch (e) {
    print("revoked:", e.name);
  }
}
