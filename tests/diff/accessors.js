// 1. Object literal getters & setters (named, computed, merged, normal names)
let key = "dyn";
let obj = {
    _x: 10,
    get x() { return this._x * 2; },
    set x(v) { this._x = v + 1; },
    get [key]() { return this._x + 100; },
    set [key](v) { this._x = v; },
    get: 42,
    set(a) { return a + 1; },
};
print("obj:", obj.x, obj[key], obj.get, obj.set(9));
obj.x = 20;
print("after set x:", obj._x, obj.x);
obj[key] = 5;
print("after set dyn:", obj._x, obj[key]);

// 2. Enumeration, spread, assign, JSON.stringify with getters
let src = {
    a: 1,
    get b() { return 2; },
    get c() { return this.a + 10; },
};
print("keys:", Object.keys(src));
print("values:", Object.values(src));
print("entries:", JSON.stringify(Object.entries(src)));
print("spread:", JSON.stringify({ ...src }));
print("assign:", JSON.stringify(Object.assign({}, src)));
print("json:", JSON.stringify(src));

// 3. Class getters & setters + static + inheritance + super
class Base {
    constructor(v) {
        this._v = v;
    }
    get val() { return this._v; }
    set val(x) { this._v = x * 10; }
    static get kind() { return "Base:" + this.tag; }
    static set kind(v) { this.tag = v; }
}
Base.tag = "B";

class Sub extends Base {
    constructor(v) {
        super(v);
    }
    get val() { return super.val + 1; }
    set val(x) { super.val = x + 2; }
    static get kind() { return "Sub->" + super.kind; }
}
Sub.tag = "S";

let sub = new Sub(3);
print("sub.val:", sub.val);
sub.val = 5;
print("sub.val after set:", sub.val, sub._v);
print("static:", Base.kind, Sub.kind);
Sub.kind = "Updated";
print("static after set:", Base.tag, Sub.tag, Sub.kind);

// 4. Object.defineProperty & getOwnPropertyDescriptor(s)
let target = {};
Object.defineProperty(target, "ro", { value: 7 });
print("ro desc:", JSON.stringify(Object.getOwnPropertyDescriptor(target, "ro")));
target.ro = 99; // sloppy-mode no-op
print("ro after write:", target.ro, delete target.ro, target.ro);

Object.defineProperty(target, "acc", {
    get() { return this._acc || 0; },
    set(v) { this._acc = v * 2; },
    enumerable: true,
    configurable: true,
});
target.acc = 6;
print("acc:", target.acc, Object.keys(target));

// Reconfigure configurable accessor -> data
Object.defineProperty(target, "acc", { value: 123, writable: false });
print("reconfigured:", target.acc, JSON.stringify(Object.getOwnPropertyDescriptor(target, "acc")));

// Object.defineProperties & getOwnPropertyDescriptors
let multi = Object.defineProperties({}, {
    p1: { value: 10, enumerable: true, writable: true, configurable: true },
    p2: { get() { return this.p1 + 5; }, enumerable: true, configurable: false },
});
print("multi:", multi.p1, multi.p2, Object.keys(multi));
let descs = Object.getOwnPropertyDescriptors(multi);
print("descs:", descs.p1.value, descs.p1.writable, typeof descs.p2.get, descs.p2.configurable);

// 5. Descriptor validation errors
let badDescs = [
    () => Object.defineProperty(1, "x", {}),
    () => Object.defineProperty({}, "x", 1),
    () => Object.defineProperty({}, "x", { value: 1, get() {} }),
    () => Object.defineProperty({}, "x", { writable: true, set() {} }),
    () => Object.defineProperty({}, "x", { get: 123 }),
    () => Object.defineProperty({}, "x", { set: "nope" }),
    () => Object.defineProperty(target, "ro", { configurable: true }),
    () => Object.defineProperty(target, "ro", { enumerable: true }),
    () => Object.defineProperty(target, "ro", { value: 8 }),
    () => Object.defineProperty(target, "ro", { writable: true }),
    () => Object.defineProperty(target, "ro", { get() {} }),
];
for (let i = 0; i < badDescs.length; i++) {
    try {
        badDescs[i]();
        print("bad", i, "no-throw");
    } catch (e) {
        print("bad", i, e.name);
    }
}
