// Error constructors, prototypes, toString, cause, AggregateError, engine-thrown errors, and conversions.

// 1. All 8 constructors with and without `new`
const ctors = [Error, TypeError, RangeError, SyntaxError, ReferenceError, EvalError, URIError];
const names = ["Error", "TypeError", "RangeError", "SyntaxError", "ReferenceError", "EvalError", "URIError"];
for (let i = 0; i < ctors.length; i++) {
    const C = ctors[i];
    const e1 = new C("boom");
    const e2 = C("boom");
    const e3 = new C();
    print(
        names[i],
        e1.name, e1.message, e1.constructor === C, C.prototype.constructor === C,
        e2.name, e2.message, e2.constructor === C,
        e3.name, e3.message, Object.keys(e1).length, Object.keys(e3).length
    );
    print(String(e1), "" + e1, `${e1}`);
    print(e1);
    print(String(e3));
}

// 2. Prototype chain
print(Object.getPrototypeOf(Error.prototype) === Object.getPrototypeOf({}));
print(Object.getPrototypeOf(TypeError.prototype) === Error.prototype);
print(Object.getPrototypeOf(RangeError.prototype) === Error.prototype);
print(Object.getPrototypeOf(SyntaxError.prototype) === Error.prototype);
print(Object.getPrototypeOf(ReferenceError.prototype) === Error.prototype);
print(Object.getPrototypeOf(EvalError.prototype) === Error.prototype);
print(Object.getPrototypeOf(URIError.prototype) === Error.prototype);
print(Object.getPrototypeOf(AggregateError.prototype) === Error.prototype);

// 3. Message coercion and undefined
const eu = new Error(undefined);
print(eu.message === "", String(eu));
const en = new Error(123);
print(en.message === "123", String(en));
const eo = new Error({ toString: ({}).toString });
print(eo.message, String(eo));

// 4. `cause` option
const ec1 = new Error("m", { cause: 42 });
print(ec1.cause, "cause" in ec1, Object.keys(ec1).length);
const ec2 = new Error("m", { cause: undefined });
print(ec2.cause === undefined, "cause" in ec2);
const ec3 = new Error("m", {});
print("cause" in ec3);
const ec4 = new Error("m", 123);
const ec5 = new Error("m", null);
print("cause" in ec4, "cause" in ec5);
const causeProto = { cause: "inherited" };
const ec6 = new TypeError("m", Object.create(causeProto));
print(ec6.cause, "cause" in ec6);

// 5. AggregateError with and without `new`, iterables, cause, non-iterable
const ae1 = new AggregateError([1, 2], "many", { cause: "root" });
const ae2 = AggregateError(new Set(["a", "b"]), "set");
const ae3 = new AggregateError("xy");
print(ae1.name, ae1.message, ae1.cause, Array.isArray(ae1.errors), ae1.errors.join(","), ae1.constructor === AggregateError);
print(ae2.name, ae2.message, ae2.errors.join(","), String(ae2));
print(ae3.name, ae3.message, ae3.errors.join(","), String(ae3));
try {
    new AggregateError(123, "bad");
} catch (e) {
    print("agg non-iter:", e instanceof TypeError, e.name);
}

// 6. Error.prototype.toString edge cases
const et1 = new Error("msg");
et1.name = "";
print("empty name:", String(et1));
const et2 = new Error("");
print("empty msg:", String(et2));
const et3 = new Error("");
et3.name = "";
print("both empty:", String(et3) === "");
const et4 = Object.create(Error.prototype);
et4.name = undefined;
et4.message = "m";
print("undef name:", String(et4));
const et5 = Object.create(Error.prototype);
et5.name = "Custom";
et5.message = undefined;
print("undef msg:", String(et5));
try {
    const ts = Error.prototype.toString;
    ts();
} catch (e) {
    print("toString non-obj:", e instanceof TypeError);
}

// 7. Other objects' String/print unchanged
print({}, [1, 2]);
print(String({}), String([1, 2]));

// 8. Engine-thrown errors of each kind
try {
    null.x;
} catch (e) {
    print("engine TypeError:", e instanceof TypeError, e instanceof Error, e.constructor === TypeError, e.name, String(e).slice(0, 9));
}
try {
    undeclared_xyz_var;
} catch (e) {
    print("engine ReferenceError:", e instanceof ReferenceError, e instanceof Error, e.constructor === ReferenceError, e.name);
}
try {
    const a = [];
    a.length = -1;
} catch (e) {
    print("engine RangeError:", e instanceof RangeError, e instanceof Error, e.constructor === RangeError, e.name);
}
try {
    JSON.parse("{");
} catch (e) {
    print("engine SyntaxError:", e instanceof SyntaxError, e instanceof Error, e.constructor === SyntaxError, e.name);
}

// 9. Errors caught across native callbacks (Array.map throwing)
try {
    [1, 2, 3].map((x) => {
        if (x === 2) null.y;
        return x;
    });
} catch (e) {
    print("map throw:", e instanceof TypeError, e instanceof Error, e.name);
}

// 10. Promise.any AggregateError and self-resolution TypeError
Promise.any([Promise.reject("r1"), Promise.reject("r2")]).catch((e) => {
    print("Promise.any:", e instanceof AggregateError, e instanceof Error, e.constructor === AggregateError, e.errors.join(","), String(e));
});
let res;
const selfP = new Promise((r) => { res = r; });
res(selfP);
selfP.catch((e) => {
    print("self-res:", e instanceof TypeError, e instanceof Error, e.constructor === TypeError, e.name);
});
