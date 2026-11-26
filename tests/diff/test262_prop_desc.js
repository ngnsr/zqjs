// Conformance diff test for built-in global property descriptors (configurable/deletable)
// and ES6+/ES2025 Math methods (acosh, asinh, atanh, cbrt, cosh, expm1, f16round, log10, log1p, log2, sinh, tanh).

const getDesc = Object.getOwnPropertyDescriptor;
const defProp = Object.defineProperty;
const hasOwn = Function.prototype.call.bind(Object.prototype.hasOwnProperty);

function checkConfigurableGlobal(name) {
    const d = getDesc(globalThis, name);
    const attrs = d && d.writable === true && d.enumerable === false && d.configurable === true;
    const delOk = delete globalThis[name];
    const goneOwn = !hasOwn(globalThis, name);
    const goneDesc = getDesc(globalThis, name) === undefined;
    const goneIn = !(name in globalThis);
    const goneProp = globalThis[name] === undefined;
    defProp(globalThis, name, d);
    const restored = hasOwn(globalThis, name) && globalThis[name] === d.value;
    print("global", name, attrs, delOk, goneOwn, goneDesc, goneIn, goneProp, restored);
}

for (const name of [
    "Object",
    "Array",
    "ArrayBuffer",
    "BigInt",
    "BigInt64Array",
    "BigUint64Array",
    "Boolean",
    "Date",
    "Error",
    "EvalError",
    "RangeError",
    "ReferenceError",
    "SyntaxError",
    "TypeError",
    "URIError",
    "AggregateError",
    "Function",
    "Iterator",
    "JSON",
    "Math",
    "Number",
    "Reflect",
    "RegExp",
    "String",
    "parseInt",
    "parseFloat",
    "isNaN",
    "isFinite",
    "encodeURI",
    "decodeURI",
    "encodeURIComponent",
    "decodeURIComponent",
]) {
    checkConfigurableGlobal(name);
}

// Deleted built-in global throws ReferenceError on identifier read
{
    const d = getDesc(globalThis, "Math");
    delete globalThis.Math;
    let err = "none";
    try {
        void Math;
    } catch (e) {
        err = e.name;
    }
    defProp(globalThis, "Math", d);
    print("deleted Math ref:", err, Math.abs(-3));
}

// Immutable value globals remain non-writable and non-configurable
for (const name of ["undefined", "NaN", "Infinity"]) {
    const d = getDesc(globalThis, name);
    const delRes = delete globalThis[name];
    print("const global", name, d.writable, d.enumerable, d.configurable, delRes, hasOwn(globalThis, name));
}

// Math methods descriptors, name, length, and key values
const mathMethods = [
    "acosh",
    "asinh",
    "atanh",
    "cbrt",
    "cosh",
    "expm1",
    "f16round",
    "log10",
    "log1p",
    "log2",
    "sinh",
    "tanh",
];

for (const name of mathMethods) {
    const d = getDesc(Math, name);
    const fn = Math[name];
    print(
        "Math." + name,
        typeof fn,
        fn.name === name,
        fn.length,
        d.writable,
        d.enumerable,
        d.configurable
    );
}

// Key edge cases for each Math method
print("acosh:", Number.isNaN(Math.acosh(0.5)), Object.is(Math.acosh(1), 0), Math.acosh(Infinity));
print("asinh:", Object.is(Math.asinh(-0), -0), Object.is(Math.asinh(0), 0), Math.asinh(-Infinity), Math.asinh(Infinity));
print("atanh:", Number.isNaN(Math.atanh(2)), Math.atanh(-1), Math.atanh(1), Object.is(Math.atanh(-0), -0));
print("cbrt:", Math.cbrt(27), Math.cbrt(-8), Object.is(Math.cbrt(-0), -0), Math.cbrt(-Infinity));
print("cosh:", Math.cosh(0), Math.cosh(-0), Math.cosh(-Infinity), Number.isNaN(Math.cosh(NaN)));
print("expm1:", Object.is(Math.expm1(-0), -0), Object.is(Math.expm1(0), 0), Math.expm1(-Infinity), Math.expm1(Infinity));
print("f16round:", Math.f16round(1.5), Math.f16round(1.337), Object.is(Math.f16round(-0), -0), Math.f16round(100000), Number.isNaN(Math.f16round(NaN)));
print("log10:", Math.log10(1000), Object.is(Math.log10(1), 0), Math.log10(0), Math.log10(-0), Number.isNaN(Math.log10(-1)));
print("log1p:", Object.is(Math.log1p(-0), -0), Object.is(Math.log1p(0), 0), Math.log1p(-1), Number.isNaN(Math.log1p(-2)), Math.log1p(Infinity));
print("log2:", Math.log2(1024), Object.is(Math.log2(1), 0), Math.log2(0), Math.log2(-0), Number.isNaN(Math.log2(-1)));
print("sinh:", Object.is(Math.sinh(-0), -0), Object.is(Math.sinh(0), 0), Math.sinh(-Infinity), Math.sinh(Infinity));
print("tanh:", Object.is(Math.tanh(-0), -0), Object.is(Math.tanh(0), 0), Math.tanh(Infinity), Math.tanh(-Infinity));
