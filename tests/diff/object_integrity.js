// Object.create(proto, props)
const base = { inherited: 42 };
const created = Object.create(base, {
    a: { value: 1, enumerable: true, writable: true, configurable: true },
    b: { get() { return this.a + 10; }, enumerable: true, configurable: true },
    hidden: { value: 99, enumerable: false },
});
print("create:", created.inherited, created.a, created.b, created.hidden);
print("create keys:", Object.keys(created).join(","));

// Object.setPrototypeOf
const p1 = { x: 10 };
const p2 = { x: 20 };
const o = { y: 1 };
Object.setPrototypeOf(o, p1);
print("setProto1:", o.x, Object.getPrototypeOf(o) === p1);
Object.setPrototypeOf(o, p2);
print("setProto2:", o.x, Object.getPrototypeOf(o) === p2);
Object.setPrototypeOf(o, null);
print("setProtoNull:", Object.getPrototypeOf(o), o.x);

// Cycle check
try {
    Object.setPrototypeOf(p1, p1);
    print("cycle: no throw");
} catch (e) {
    print("cycle:", e.name);
}
const c1 = {};
const c2 = Object.create(c1);
try {
    Object.setPrototypeOf(c1, c2);
    print("cycle2: no throw");
} catch (e) {
    print("cycle2:", e.name);
}

// Primitives
print("primExt:", Object.isExtensible(1), Object.isSealed(1), Object.isFrozen(1));
print("primFreeze:", Object.freeze("hi"), Object.seal(42), Object.preventExtensions(true));
print("primSetProto:", Object.setPrototypeOf(42, {}));

// preventExtensions / seal / freeze on ordinary objects
const pe = { a: 1 };
Object.preventExtensions(pe);
print("pe:", Object.isExtensible(pe), Object.isSealed(pe), Object.isFrozen(pe));
pe.b = 2; // sloppy no-op
pe.a = 3;
print("pe after:", pe.a, pe.b, Object.hasOwn(pe, "b"));
Object.setPrototypeOf(pe, Object.getPrototypeOf(pe)); // same proto is a no-op
try {
    Object.setPrototypeOf(pe, {});
    print("pe setProto: no throw");
} catch (e) {
    print("pe setProto:", e.name);
}

const sl = { a: 1 };
Object.seal(sl);
print("sl:", Object.isExtensible(sl), Object.isSealed(sl), Object.isFrozen(sl));
sl.a = 2;
print("sl write:", sl.a, delete sl.a);

const fr = { a: 1, get g() { return this.a + 1; } };
Object.freeze(fr);
print("fr:", Object.isExtensible(fr), Object.isSealed(fr), Object.isFrozen(fr));
fr.a = 99;
print("fr write:", fr.a, fr.g, delete fr.a);
try {
    Object.assign(fr, { a: 100 });
    print("fr assign: no throw");
} catch (e) {
    print("fr assign:", e.name);
}

// Manually locked object
const man = { a: 1 };
Object.defineProperty(man, "a", { writable: false, configurable: false });
Object.preventExtensions(man);
print("manual:", Object.isSealed(man), Object.isFrozen(man));

// Arrays: preventExtensions / seal / freeze + mutators
const peArr = [1];
Object.preventExtensions(peArr);
print("peArr pe:", Object.isExtensible(peArr), Object.isSealed(peArr), Object.isFrozen(peArr));

const arr = [1, 2, 3];
Object.freeze(arr);
print("arr fr:", Object.isExtensible(arr), Object.isSealed(arr), Object.isFrozen(arr));
arr[0] = 99;
arr[3] = 4;
arr.length = 1;
print("arr sloppy:", arr.length, arr[0]);
for (const fn of [
    () => arr.push(4),
    () => arr.pop(),
    () => arr.shift(),
    () => arr.unshift(0),
    () => arr.reverse(),
    () => arr.sort(),
    () => arr.fill(0),
    () => arr.splice(0, 1),
]) {
    try {
        fn();
        print("arr mut: no throw");
    } catch (e) {
        print("arr mut:", e.name);
    }
}

// RegExp & Function freeze/seal
const re = /abc/g;
Object.freeze(re);
re.lastIndex = 5;
print("re frozen:", Object.isFrozen(re), re.lastIndex);

function fnTest(a, b) {}
Object.freeze(fnTest);
print("fn frozen:", Object.isSealed(fnTest), Object.isFrozen(fnTest));

// hasOwn, hasOwnProperty, isPrototypeOf, propertyIsEnumerable
const parent = { p: 1 };
const ch = Object.create(parent);
ch.own = 2;
Object.defineProperty(ch, "nonEnum", { value: 3, enumerable: false });
print("hasOwn:", Object.hasOwn(ch, "own"), Object.hasOwn(ch, "p"), Object.hasOwn(ch, "nonEnum"));
print("hasOwnProp:", ch.hasOwnProperty("own"), ch.hasOwnProperty("p"));
print("isProtoOf:", parent.isPrototypeOf(ch), Object.prototype.isPrototypeOf(ch), ch.isPrototypeOf(parent), parent.isPrototypeOf(42));
print("propIsEnum:", ch.propertyIsEnumerable("own"), ch.propertyIsEnumerable("nonEnum"), ch.propertyIsEnumerable("p"));

// getOwnPropertyNames, Object.is, Object.fromEntries
print("gopn:", Object.getOwnPropertyNames(ch).join(","));
print("is:", Object.is(NaN, NaN), Object.is(+0, -0), Object.is(0, 0));
const fe = Object.fromEntries([["a", 1], ["b", 2]]);
print("fromEntries:", fe.a, fe.b);
