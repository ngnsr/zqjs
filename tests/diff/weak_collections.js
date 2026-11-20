// WeakMap & WeakSet differential tests (M45, D75)

// 1. Constructors without `new`
try { WeakMap(); } catch (e) { print("wm no-new:", e.name); }
try { WeakSet(); } catch (e) { print("ws no-new:", e.name); }

// 2. Empty and iterable constructors
const k1 = { name: "k1" };
const k2 = function () {};
const k3 = [1, 2, 3];
const s1 = Symbol("local");
const sGlobal = Symbol.for("global-key");

const wm0 = new WeakMap();
const wm1 = new WeakMap([[k1, 10], [k2, "fn"], [k3, true], [s1, "sym"]]);
print("wm1:", wm1.get(k1), wm1.get(k2), wm1.get(k3), wm1.get(s1), wm1.has(k1), wm1.has({}));

const ws0 = new WeakSet();
const ws1 = new WeakSet([k1, k2, k3, s1]);
print("ws1:", ws1.has(k1), ws1.has(k2), ws1.has(k3), ws1.has(s1), ws1.has({}));

// 3. null / undefined iterable
print("wm null:", new WeakMap(null).has(k1), new WeakMap(undefined).has(k1));
print("ws null:", new WeakSet(null).has(k1), new WeakSet(undefined).has(k1));

// 4. Custom [Symbol.iterator] and IteratorClose on error
let closed = false;
const badIter = {
  [Symbol.iterator]() {
    let i = 0;
    return {
      next() {
        i++;
        if (i === 1) return { value: [k1, 1], done: false };
        if (i === 2) return { value: "not-an-entry", done: false };
        return { done: true };
      },
      return() {
        closed = true;
        return { done: true };
      }
    };
  }
};
try { new WeakMap(badIter); } catch (e) { print("wm bad entry:", e.name, "closed:", closed); }

let closedKey = false;
const badKeyIter = {
  [Symbol.iterator]() {
    return {
      next() { return { value: [123, "v"], done: false }; },
      return() { closedKey = true; return { done: true }; }
    };
  }
};
try { new WeakMap(badKeyIter); } catch (e) { print("wm bad key:", e.name, "closed:", closedKey); }

let closedSet = false;
const badSetIter = {
  [Symbol.iterator]() {
    return {
      next() { return { value: Symbol.for("reg"), done: false }; },
      return() { closedSet = true; return { done: true }; }
    };
  }
};
try { new WeakSet(badSetIter); } catch (e) { print("ws bad key:", e.name, "closed:", closedSet); }

// 5. Invalid keys on set/add vs get/has/delete
const invalids = [undefined, null, true, false, 0, -0, 42, NaN, "str", sGlobal];
for (const bad of invalids) {
  let wmErr = false;
  try { wm0.set(bad, 1); } catch (e) { if (e.name === "TypeError") wmErr = true; }
  let wsErr = false;
  try { ws0.add(bad); } catch (e) { if (e.name === "TypeError") wsErr = true; }
  if (!wmErr || !wsErr) print("FAIL invalid key did not throw:", typeof bad);
  if (wm0.get(bad) !== undefined || wm0.has(bad) !== false || wm0.delete(bad) !== false) {
    print("FAIL wm invalid lookup");
  }
  if (ws0.has(bad) !== false || ws0.delete(bad) !== false) {
    print("FAIL ws invalid lookup");
  }
}
print("invalids ok");

// 6. Chaining, overwriting, deleting, native function keys, class keys
class Box {}
const nativeFn = Math.max;
const wm2 = new WeakMap();
const retWm = wm2.set(k1, "a").set(k1, "b").set(Box, "cls").set(nativeFn, "nat");
print("chain wm:", retWm === wm2, wm2.get(k1), wm2.get(Box), wm2.get(nativeFn));
print("del wm:", wm2.delete(k1), wm2.delete(k1), wm2.has(k1), wm2.get(k1));

const ws2 = new WeakSet();
const retWs = ws2.add(k1).add(k1).add(Box).add(nativeFn);
print("chain ws:", retWs === ws2, ws2.has(Box), ws2.has(nativeFn));
print("del ws:", ws2.delete(Box), ws2.delete(Box), ws2.has(Box));

// 7. instanceof, toStringTag, constructor, incompatible receiver
print("instanceof:", wm2 instanceof WeakMap, ws2 instanceof WeakSet);
print("toString:", Object.prototype.toString.call(wm2), Object.prototype.toString.call(ws2));
print("ctor:", WeakMap.prototype.constructor === WeakMap, WeakSet.prototype.constructor === WeakSet);

for (const fn of [
  () => WeakMap.prototype.get.call({}, k1),
  () => WeakMap.prototype.set.call({}, k1, 1),
  () => WeakMap.prototype.has.call([], k1),
  () => WeakMap.prototype.delete.call(ws2, k1),
  () => WeakSet.prototype.add.call({}, k1),
  () => WeakSet.prototype.has.call(wm2, k1),
  () => WeakSet.prototype.delete.call(null, k1),
]) {
  try { fn(); print("FAIL receiver"); } catch (e) { print("recv:", e.name); }
}
