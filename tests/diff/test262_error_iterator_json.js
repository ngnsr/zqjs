// Conformance diff test for Error.prototype.stack, Iterator.prototype.{drop,take},
// and JSON.parse reviver (InternalizeJSONProperty).

function errName(fn) {
    try {
        fn();
        return "ok";
    } catch (e) {
        return e.name;
    }
}

// 1. Error stack read/write
const err = new Error("boom");
print("err stack type:", typeof err.stack);
err.stack = "custom-stack";
print("err stack set:", err.stack);

// 2. Iterator.prototype.take with MAX_SAFE_INTEGER
const validIt = (function* () {
    yield 10;
    yield 20;
})();
print("take MAX_SAFE:", validIt.take(Number.MAX_SAFE_INTEGER).toArray().join(","));

// 3. JSON.parse reviver: Proxy objects & arrays, IsArray, ToLength, CreateDataProperty
let visitedOther = false;
const objProxy = new Proxy({ length: 0, other: 1 }, {});
JSON.parse("[null, null]", function (k, v) {
    if (k === "other") visitedOther = true;
    this[1] = objProxy;
    return v;
});
print("revived objProxy:", visitedOther);

visitedOther = false;
const arrProxy = new Proxy([], {});
arrProxy.other = 1;
JSON.parse("[null, null]", function (k, v) {
    if (k === "other") visitedOther = true;
    this[1] = arrProxy;
    return v;
});
print("revived arrProxy skips non-index:", visitedOther);

const revocable = Proxy.revocable([], {});
revocable.revoke();
print(
    "revived revoked proxy:",
    errName(() =>
        JSON.parse("[0, 0]", function (k, v) {
            this[1] = revocable.proxy;
            return v;
        })
    )
);

const badLen = new Proxy([], {
    get(_, k) {
        if (k === "length") throw new RangeError("len-err");
    },
});
print(
    "reviver bad length:",
    errName(() =>
        JSON.parse("[0, 0]", function () {
            this[1] = badLen;
        })
    )
);

const badDefine = new Proxy([null], {
    defineProperty() {
        throw new RangeError("def-err");
    },
});
print(
    "reviver array define err:",
    errName(() =>
        JSON.parse('["a", null]', function (_, v) {
            if (v === "a") this[1] = badDefine;
            return v;
        })
    )
);

const badDelete = new Proxy([0], {
    deleteProperty() {
        throw new RangeError("del-err");
    },
});
print(
    "reviver array delete err:",
    errName(() =>
        JSON.parse("[0, 0]", function () {
            this[1] = badDelete;
        })
    )
);

Object.prototype.inherited_b = 3;
const protoObj = JSON.parse('{"a": 1, "inherited_b": 2}', function (k, v) {
    if (k === "a") delete this.inherited_b;
    return v;
});
delete Object.prototype.inherited_b;
print("reviver proto prop:", protoObj.a, protoObj.inherited_b, Object.prototype.hasOwnProperty.call(protoObj, "inherited_b"));

const nonConfObj = JSON.parse('{"a": 1, "b": 2}', function (k, v) {
    if (k === "a") Object.defineProperty(this, "b", { configurable: false });
    if (k === "b") return 22;
    return v;
});
print("reviver non-conf:", nonConfObj.a, nonConfObj.b);
