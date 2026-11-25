// Conformance diff test for Object.prototype.toString on built-in iterators
// and JSON.stringify replacer array / deleted property edge cases.

function errName(fn) {
    try {
        fn();
        return "ok";
    } catch (e) {
        return e.name;
    }
}

// 1. Object.prototype.toString with Array/Map/Set Iterator prototypes
const toString = Object.prototype.toString;

function checkIterTag(label, iter, expectedDefault, nonStringDesc) {
    const proto = Object.getPrototypeOf(iter);
    const origDesc = Object.getOwnPropertyDescriptor(proto, Symbol.toStringTag);
    print(label, "default:", toString.call(iter) === expectedDefault, toString.call(iter));
    Object.defineProperty(proto, Symbol.toStringTag, nonStringDesc);
    print(label, "non-string:", toString.call(iter));
    delete proto[Symbol.toStringTag];
    print(label, "deleted:", toString.call(iter));
    Object.defineProperty(proto, Symbol.toStringTag, origDesc);
}

checkIterTag("arrIter", [][Symbol.iterator](), "[object Array Iterator]", {
    configurable: true,
    value: null,
});
checkIterTag("mapIter", new Map()[Symbol.iterator](), "[object Map Iterator]", {
    configurable: true,
    get() {
        return new String("ShouldNotBeUnwrapped");
    },
});
checkIterTag("setIter", new Set()[Symbol.iterator](), "[object Set Iterator]", {
    configurable: true,
    get() {
        return new String("ShouldNotBeUnwrapped");
    },
});

// 2. JSON.stringify replacer array: Proxy, revoked Proxy, abrupt length
const proxyReplacer = new Proxy(["b"], {});
print("proxy replacer flat:", JSON.stringify({ a: 1, b: 2 }, proxyReplacer));
print("proxy replacer nested:", JSON.stringify({ b: { a: 3, b: 4 } }, proxyReplacer));

const rev = Proxy.revocable([], {});
rev.revoke();
print("revoked proxy replacer:", errName(() => JSON.stringify({}, rev.proxy)));

const abruptLen = new Proxy([], {
    get(_, k) {
        if (k === "length") throw new RangeError("abrupt-len");
    },
});
print("abrupt length replacer:", errName(() => JSON.stringify(null, abruptLen)));

const abruptToLen = new Proxy([], {
    get(_, k) {
        if (k === "length") {
            return {
                valueOf() {
                    throw new RangeError("abrupt-tolen");
                },
            };
        }
    },
});
print("abrupt toLength replacer:", errName(() => JSON.stringify([], abruptToLen)));

// 3. JSON.stringify replacer array: Number and String wrapper objects use ToString
const numObj = new Number(10);
numObj.toString = () => "toString";
numObj.valueOf = () => {
    throw new Error("should not call valueOf");
};
print("replacer Number obj:", JSON.stringify({ 10: 1, toString: 2, valueOf: 3 }, [numObj]));

const strObj = new String("str");
strObj.toString = () => "toString";
strObj.valueOf = () => {
    throw new Error("should not call valueOf");
};
print("replacer String obj:", JSON.stringify({ str: 1, toString: 2, valueOf: 3 }, [strObj]));

// 4. JSON.stringify replacer function sees deleted property from earlier getter
const mutObj = {
    get a() {
        delete this.b;
        return 1;
    },
    b: 2,
};
const res = JSON.stringify(mutObj, (key, value) => {
    if (key === "b") return value === undefined ? "<replaced>" : value;
    return value;
});
print("deleted prop replacer:", res);
