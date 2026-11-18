// M31: User constructors (new F(), new F(...args)), instanceof, return override, and bound constructors.

function Point(x, y) {
    this.x = x;
    this.y = y;
}
Point.prototype.sum = function () {
    return this.x + this.y;
};

const p1 = new Point(3, 4);
const p2 = new Point(...[10, 20]);
print("p1:", p1.x, p1.y, p1.sum());
print("p2:", p2.x, p2.y, p2.sum());
print("proto:", Object.getPrototypeOf(p1) === Point.prototype);
print("ctor:", p1.constructor === Point);
print("inst:", p1 instanceof Point, p1 instanceof Object, p1 instanceof Array);

// Constructor without explicit return, and primitive returns keep `this`
function RetPrim(v) {
    this.ok = true;
    return v;
}
for (const v of [undefined, null, 42, "str", false]) {
    const r = new RetPrim(v);
    print("retPrim:", r.ok, r instanceof RetPrim);
}

// Object or function return overrides `this`
function RetObj() {
    this.ignored = true;
    return { custom: 99 };
}
const ro = new RetObj();
print("retObj:", ro.custom, ro.ignored, ro instanceof RetObj);

function RetFn() {
    this.ignored = true;
    return () => "fn";
}
const rf = new RetFn();
print("retFn:", rf(), rf instanceof Function, rf instanceof RetFn);

// Replacing F.prototype
function Box(v) {
    this.v = v;
}
const b1 = new Box(1);
const customProto = { tag: "custom" };
Box.prototype = customProto;
const b2 = new Box(2);
print("replaced:", b1 instanceof Box, b2 instanceof Box, b2.tag, Object.getPrototypeOf(b2) === customProto);

// Primitive/null F.prototype: new falls back to Object.prototype, instanceof throws TypeError
Box.prototype = null;
const b3 = new Box(3);
print("nullProtoInst:", Object.getPrototypeOf(b3) === Object.prototype, b3.v);
for (const badProto of [null, 42, "str"]) {
    Box.prototype = badProto;
    try {
        b3 instanceof Box;
        print("FAIL");
    } catch (e) {
        print("badProtoInstanceof:", e.name);
    }
}

// Bound constructor: ignores boundThis, prepends boundArgs, instanceof works against target
const BoundPoint = Point.bind({ x: 999 }, 5);
const bp = new BoundPoint(6);
print("boundCtor:", bp.x, bp.y, bp.sum(), bp instanceof Point, bp instanceof BoundPoint);

// Non-constructors throw TypeError on `new`
const arrow = () => {};
async function asyncFn() {}
const obj = { m() {}, async am() {} };
const boundArrow = arrow.bind(null);
for (const nonCtor of [arrow, asyncFn, obj.m, obj.am, parseInt, Math.abs, [].push, boundArrow, 123, null]) {
    try {
        new nonCtor();
        print("FAIL");
    } catch (e) {
        print("nonCtor:", e.name);
    }
}
