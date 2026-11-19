// Own + inherited keys, ordering (array indices ascending, then insertion order)
const proto = { p1: 10, p2: 20, "1": "proto1" };
const obj = Object.create(proto);
obj.b = 2;
obj["10"] = "ten";
obj["2"] = "two";
obj.a = 1;
const keys = [];
for (const k in obj) keys.push(k);
print("order:", keys.join(","));

// Non-enumerable shadowing an enumerable prototype key
const pShadow = { x: 1, y: 2 };
const child = Object.create(pShadow);
Object.defineProperty(child, "x", { value: 99, enumerable: false });
const shadowKeys = [];
for (const k in child) shadowKeys.push(k);
print("shadow:", shadowKeys.join(","));

// Symbols are never visited
const sym = Symbol("s");
const withSym = { a: 1, [sym]: 2 };
const symKeys = [];
for (const k in withSym) symKeys.push(k);
print("sym:", symKeys.join(","));

// Dynamic deletion during iteration
const dyn = { a: 1, b: 2, c: 3 };
const dynKeys = [];
for (const k in dyn) {
    dynKeys.push(k);
    if (k === "a") delete dyn.b;
}
print("delete:", dynKeys.join(","));

// null, undefined, primitives, strings, arrays
for (const k in null) print("null:", k);
for (const k in undefined) print("undef:", k);
for (const k in 42) print("num:", k);
for (const k in true) print("bool:", k);
for (const k in Symbol("x")) print("symval:", k);

const strKeys = [];
for (const k in "hi") strKeys.push(k);
print("str:", strKeys.join(","));

const arr = [10, 20];
arr.extra = 30;
const arrKeys = [];
for (const k in arr) arrKeys.push(k);
print("arr:", arrKeys.join(","));

// break, continue, labels, return, try/finally, nested loops
function testControl() {
    const out = [];
    outer: for (const a in { x: 1, y: 2, z: 3 }) {
        if (a === "y") continue;
        for (const b in { m: 1, n: 2 }) {
            out.push(a + b);
            if (a === "z") break outer;
        }
    }
    return out.join(",");
}
print("control:", testControl());

function testReturnFinally() {
    const log = [];
    for (const k in { a: 1, b: 2 }) {
        try {
            log.push("try:" + k);
            if (k === "a") return log.join(",");
        } finally {
            log.push("fin:" + k);
        }
    }
    return log.join(",");
}
print("retfin:", testReturnFinally());

// Per-iteration let/const closures
const fns = [];
for (let k in { p: 1, q: 2, r: 3 }) {
    fns.push(() => k);
}
print("closures:", fns.map((f) => f()).join(","));

// Member and destructuring targets
const holder = {};
const mOut = [];
for (holder.k in { u: 1, v: 2 }) mOut.push(holder.k);
print("member:", mOut.join(","), holder.k);

const dOut = [];
for (const [c0, c1] in { ab: 1, cd: 2 }) dOut.push(c0 + "-" + c1);
print("destr:", dOut.join(","));
