function catchName(fn) {
    try {
        fn();
        return "NO_THROW";
    } catch (e) {
        return e.name;
    }
}

// 1. Creation, uniqueness, description, prototype, non-constructable
const s0 = Symbol();
const s1 = Symbol("desc");
const s2 = Symbol("desc");
const sEmpty = Symbol("");
const sUndef = Symbol(undefined);
const sNum = Symbol(123);
const sNull = Symbol(null);
const sBool = Symbol(true);

print("uniq:", s1 === s2, s1 === s1, s1 !== s2, typeof s0, typeof s1);
print("desc:", s0.description, s1.description, sEmpty.description === "", sEmpty.description, sUndef.description, sNum.description, sNull.description, sBool.description);
print("str:", s0.toString(), s1.toString(), sEmpty.toString(), String(s1), String(s0));
print("valueOf:", s1.valueOf() === s1);
print("print:", s0, s1);
print("proto:", Object.getPrototypeOf(s1) === Symbol.prototype, Symbol.prototype.constructor === Symbol, Object.prototype.toString.call(s1));

print("new Symbol:", catchName(() => new Symbol()));
print("extends Symbol:", catchName(() => {
    class C extends Symbol {}
    return new C();
}));
print("Symbol(Symbol()):", catchName(() => Symbol(s1)));

// 2. Conversions
print("bool:", !s0, !s1, !!s0, !!s1, s0 ? 1 : 0);
print("unary+:", catchName(() => +s1));
print("add:", catchName(() => "" + s1));
print("template:", catchName(() => `${s1}`));
print("lt:", catchName(() => s1 < 1));
print("join:", catchName(() => [s1].join()));

// 3. Global symbol registry: Symbol.for / Symbol.keyFor
const g1 = Symbol.for("alpha");
const g2 = Symbol.for("alpha");
const gEmpty = Symbol.for("");
const gUndef = Symbol.for();
const gNum = Symbol.for(42);
print("for eq:", g1 === g2, g1.description, gEmpty.description === "", gUndef.description === "undefined", gNum === Symbol.for("42"));
print("keyFor:", Symbol.keyFor(g1), Symbol.keyFor(gEmpty) === "", Symbol.keyFor(gUndef), Symbol.keyFor(s1), Symbol.keyFor(Symbol.iterator));
print("keyFor non-sym:", catchName(() => Symbol.keyFor(123)), catchName(() => Symbol.keyFor("alpha")), catchName(() => Symbol.keyFor()));
print("for sym:", catchName(() => Symbol.for(s1)));

// 4. Symbol property keys: object literals, classes, arrays, functions, prototype chain
const symA = Symbol("a");
const symB = Symbol("b");
const symM = Symbol("m");
const symG = Symbol("g");
const symF = Symbol("f");
const symSF = Symbol("sf");
const symS = Symbol("s");

const obj = {
    str: 1,
    [symA]: 10,
    [symB]: 20,
    [symM](x) { return x + this[symA]; },
    _acc: 5,
    get [symG]() { return this._acc * 2; },
    set [symG](v) { this._acc = v + 1; },
};
print("obj reads:", obj[symA], obj[symB], obj[symM](7), obj[symG], symA in obj, Symbol("other") in obj);
obj[symG] = 9;
obj[symA] += 5;
print("obj mutated:", obj[symG], obj._acc, obj[symA]);
print("delete:", delete obj[symB], symB in obj, obj[symB]);

class Base {
    [symF] = 100;
    static [symSF] = 200;
    [symM]() { return "Base:" + this[symF]; }
    static [symS]() { return "BaseS:" + this[symSF]; }
    get [symG]() { return this[symF] + 1; }
}
class Sub extends Base {
    [symM]() { return super[symM]() + "->Sub"; }
    static [symS]() { return super[symS]() + "->SubS"; }
}
const inst = new Sub();
print("class:", inst[symF], Sub[symSF], inst[symM](), Sub[symS](), inst[symG]);

const arr = [1, 2];
arr[symA] = 99;
print("arr:", arr.length, arr[symA]);

function fn() { return 1; }
fn[symA] = 77;
print("fn:", fn(), fn[symA], symA in fn, delete fn[symA], symA in fn);

const child = Object.create(obj);
print("inherit:", child[symA], symA in child, Object.getOwnPropertySymbols(child).length);

// 5. Enumeration & reflection
const nonEnumSym = Symbol("hidden");
const symOrder1 = Symbol("first");
const symOrder2 = Symbol("second");
const refObj = {
    x: 1,
    0: "z",
    [symOrder1]: "one",
    y: 2,
    [symOrder2]: "two",
};
Object.defineProperty(refObj, nonEnumSym, {
    value: "secret",
    enumerable: false,
    writable: true,
    configurable: true,
});
print("keys:", Object.keys(refObj).join(","));
print("values:", Object.values(refObj).join(","));
print("entries:", JSON.stringify(Object.entries(refObj)));

const ownSyms = Object.getOwnPropertySymbols(refObj);
print("ownSyms:", ownSyms.length, ownSyms[0] === symOrder1, ownSyms[1] === symOrder2, ownSyms[2] === nonEnumSym);
print("ownSyms prim:", Object.getOwnPropertySymbols(123).length, Object.getOwnPropertySymbols("ab").length);
print("ownSyms fn:", Object.getOwnPropertySymbols(Object.assign(function () {}, { [symA]: 5 })).length);

const descHidden = Object.getOwnPropertyDescriptor(refObj, nonEnumSym);
print("descHidden:", descHidden.value, descHidden.enumerable, descHidden.writable, descHidden.configurable);
const allDescs = Object.getOwnPropertyDescriptors(refObj);
print("allDescs:", allDescs.x.value, allDescs[symOrder1].value, allDescs[nonEnumSym].value, allDescs[nonEnumSym].enumerable);

const targetDef = {};
Object.defineProperties(targetDef, {
    a: { value: 1, enumerable: true },
    [symOrder1]: { value: 2, enumerable: true },
    [nonEnumSym]: { value: 3, enumerable: false },
});
print("defineProps:", targetDef.a, targetDef[symOrder1], targetDef[nonEnumSym], Object.getOwnPropertySymbols(targetDef).length);

// Assign, object spread, object rest
const assigned = Object.assign({}, refObj);
print("assign:", assigned.x, assigned[symOrder1], assigned[symOrder2], nonEnumSym in assigned, Object.getOwnPropertySymbols(assigned).length);
const spreaded = { ...refObj };
print("spread:", spreaded.x, spreaded[symOrder1], spreaded[symOrder2], nonEnumSym in spreaded, Object.getOwnPropertySymbols(spreaded).length);
const { [symOrder1]: picked, ...rest } = refObj;
print("rest:", picked, symOrder1 in rest, rest[symOrder2], nonEnumSym in rest, rest.x);

// 6. JSON.stringify ignores symbol keys and symbol values (null in arrays)
print("json obj:", JSON.stringify({ a: 1, [symA]: "drop", b: symA, c: undefined }));
print("json arr:", JSON.stringify([1, symA, "x", s0]));
print("json top:", JSON.stringify(symA));

// 7. Map & Set with symbols
const map = new Map([[symA, "A"], [symB, "B"], [Symbol.for("k"), "G"]]);
print("map:", map.size, map.get(symA), map.get(symB), map.get(Symbol.for("k")), map.get(Symbol("a")));
const set = new Set([symA, symA, Symbol.for("k"), Symbol.for("k"), symB]);
print("set:", set.size, set.has(symA), set.has(Symbol.for("k")), set.has(Symbol("a")));
