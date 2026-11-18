// instanceof across built-in constructors, Error hierarchy, prototypes, primitives, and precedence.

// 1. Error hierarchy
const e = new Error("e");
const te = new TypeError("te");
const re = new RangeError("re");
const se = new SyntaxError("se");
const rfe = new ReferenceError("rfe");
const ee = new EvalError("ee");
const ue = new URIError("ue");
const ae = new AggregateError([], "ae");

print(e instanceof Error, e instanceof Object, e instanceof TypeError);
print(te instanceof TypeError, te instanceof Error, te instanceof Object, te instanceof RangeError);
print(re instanceof RangeError, re instanceof Error);
print(se instanceof SyntaxError, se instanceof Error);
print(rfe instanceof ReferenceError, rfe instanceof Error);
print(ee instanceof EvalError, ee instanceof Error);
print(ue instanceof URIError, ue instanceof Error);
print(ae instanceof AggregateError, ae instanceof Error, ae instanceof Object);

// 2. Built-in constructors
print({} instanceof Object, [] instanceof Array, [] instanceof Object);
print(new Map() instanceof Map, new Map() instanceof Object, new Map() instanceof Set);
print(new Set() instanceof Set, new Set() instanceof Object);
print(Promise.resolve(1) instanceof Promise, Promise.resolve(1) instanceof Object);
print(Object.create(null) instanceof Object);
print(Object.getPrototypeOf({}) instanceof Object);
print(Error.prototype instanceof Error, Error.prototype instanceof Object);
print(TypeError.prototype instanceof Error, TypeError.prototype instanceof TypeError);

// 3. Functions on the left
const fn = () => 1;
print(fn instanceof Object, Error instanceof Object, parseInt instanceof Object);

// 4. Primitives on the left give false (after RHS check)
print(undefined instanceof Object, null instanceof Object);
print(true instanceof Object, false instanceof Number);
print(42 instanceof Number, 42 instanceof Object);
print("abc" instanceof String, "abc" instanceof Object);
print(1 instanceof Error, 1 instanceof parseInt);

// 5. Non-callable RHS throws TypeError (even with primitive on LHS)
for (const rhs of [undefined, null, true, 123, "str", {}, []]) {
    try {
        1 instanceof rhs;
        print("FAIL");
    } catch (err) {
        print("rhs TypeError:", err instanceof TypeError, err.name);
    }
}
try {
    ({}) instanceof parseInt;
    print("FAIL");
} catch (err) {
    print("non-ctor TypeError:", err instanceof TypeError, err.name);
}

// 6. Precedence (relational, same as <, higher than ===, lower than +)
print(1 + 2 instanceof Number === false);
print([] instanceof Array === true);
print(!({} instanceof Array));
for (let x = [] instanceof Array; x; x = false) {
    print("in for-init:", x);
}
