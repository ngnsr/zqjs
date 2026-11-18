// M31: Functions as objects (name, length, prototype, own props, prototype chain, call/apply/bind).

// 1. name & length
function namedDecl(a, b) { return a + b; }
const inferredExpr = function (x, y = 1, z) { return x; };
const inferredArrow = (a, b, ...rest) => a;
let reassigned;
reassigned = () => 42;
const objMethods = {
    concise(a, b, c) { return a; },
    async asyncConcise(a) { return a; },
    propArrow: (x) => x,
    "strKey": function () {},
};
function defaultName(cb = () => {}) { return cb.name; }

print("names:", namedDecl.name, inferredExpr.name, inferredArrow.name, reassigned.name);
print("objNames:", objMethods.concise.name, objMethods.asyncConcise.name, objMethods.propArrow.name, objMethods.strKey.name);
print("anonName:", (function () {}).name, (() => {}).name, defaultName());
print("lengths:", namedDecl.length, inferredExpr.length, inferredArrow.length, objMethods.concise.length, objMethods.asyncConcise.length);
print("native:", print.name, parseInt.name, parseInt.length, Function.name, Function.length);

// 2. name & length are read-only and non-enumerable
namedDecl.name = "changed";
namedDecl.length = 999;
print("readonly:", namedDecl.name, namedDecl.length);
print("keys-fresh:", JSON.stringify(Object.keys(namedDecl)));

// 3. Own properties, delete, in, Object.keys/values/entries/assign, spread
namedDecl.tag = "fnTag";
namedDecl[0] = "zero";
namedDecl["extra"] = 123;
print("props:", namedDecl.tag, namedDecl[0], namedDecl.extra);
print("in:", "tag" in namedDecl, "name" in namedDecl, "length" in namedDecl, "prototype" in namedDecl, "call" in namedDecl, "nope" in namedDecl);
print("keys:", JSON.stringify(Object.keys(namedDecl)));
print("values:", JSON.stringify(Object.values(namedDecl)));
print("entries:", JSON.stringify(Object.entries(namedDecl)));
print("spread:", JSON.stringify({ ...namedDecl }));
print("delete:", delete namedDecl.tag, "tag" in namedDecl, delete namedDecl.prototype, "prototype" in namedDecl);
Object.assign(namedDecl, { assigned: true });
print("assigned:", namedDecl.assigned, JSON.stringify(Object.keys(namedDecl)));

// 4. Prototype chain & Function global
print("proto:", Object.getPrototypeOf(namedDecl) === Function.prototype);
print("nativeProto:", Object.getPrototypeOf(parseInt) === Function.prototype);
print("fnProtoCtor:", Function.prototype.constructor === Function);
print("instanceof:", namedDecl instanceof Function, namedDecl instanceof Object);
print("nativeInstanceof:", parseInt instanceof Function, parseInt instanceof Object);

// 5. Lazy .prototype on constructable vs non-constructable functions
print("ctorProto:", namedDecl.prototype.constructor === namedDecl);
print("ctorProtoProto:", Object.getPrototypeOf(namedDecl.prototype) === Object.prototype);
namedDecl.prototype = { custom: 7 };
print("customProto:", namedDecl.prototype.custom);

const arrowFn = () => {};
async function asyncFn() {}
print("nonCtorProto:", arrowFn.prototype, asyncFn.prototype, objMethods.concise.prototype);
print("nonCtorIn:", "prototype" in arrowFn, "prototype" in asyncFn, "prototype" in objMethods.concise);
arrowFn.prototype = 123;
print("arrowAssignProto:", arrowFn.prototype, delete arrowFn.prototype, arrowFn.prototype);

// 6. Function.prototype.call, apply, bind
function greet(prefix, suffix) {
    return prefix + ":" + this.who + suffix;
}
const ctx = { who: "world" };
print("call:", greet.call(ctx, "hi", "!"));
print("apply:", greet.apply(ctx, ["hello", "?"]));
function noThis(a, b) { return [a, b].join(","); }
print("applyNull:", noThis.apply(null, null), noThis.apply(undefined, undefined));
try {
    noThis.apply(null, 123);
    print("FAIL");
} catch (e) {
    print("applyErr:", e.name);
}

const bound1 = greet.bind(ctx, "yo");
print("boundMeta:", bound1.name, bound1.length, bound1.prototype, "prototype" in bound1);
print("boundCall:", bound1("~"));
const bound2 = bound1.bind({ who: "ignored" }, "end");
print("bound2Meta:", bound2.name, bound2.length);
print("bound2Call:", bound2());

const boundNative = Math.max.bind(null, 10, 20);
print("boundNative:", boundNative.name, boundNative(5, 30));
