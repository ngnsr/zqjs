// Conformance diff test for JSON.stringify replacer/getter rooting and Date relative-ms arithmetic.

function assertRelative(d, expectedMs) {
    return d.valueOf() - d.getTimezoneOffset() * 60000 === expectedMs;
}

// 1. Date constructor (year, month, ...): relative-ms round-trip across century boundaries
print("1969-12:", assertRelative(new Date(1969, 11), -2678400000));
print("1970-01 roll:", assertRelative(new Date(1969, 12), 0));
print("1970-01:", assertRelative(new Date(1970, 0), 0));
print("1999-12-31 23:59:59.999:", assertRelative(new Date(1999, 11, 31, 23, 59, 59, 999), 946684799999));
print("2000-01-01:", assertRelative(new Date(2000, 0, 1, 0, 0, 0, 0), 946684800000));
print("2099-12-31 23:59:59.999:", assertRelative(new Date(2099, 11, 31, 23, 59, 59, 999), 4102444799999));
print("2100-01-01:", assertRelative(new Date(2100, 0, 1, 0, 0, 0, 0), 4102444800000));

// 2. JSON.stringify replacer array with abrupt index getter (via Proxy)
const abruptIndex = new Proxy(["x"], {
    get(target, key, receiver) {
        if (key === "0") throw new RangeError("abrupt-index");
        return Reflect.get(target, key, receiver);
    },
});
try {
    JSON.stringify({}, abruptIndex);
    print("abrupt index: ok");
} catch (e) {
    print("abrupt index:", e.name, e.message);
}

// 3. JSON.stringify on array with hole getter on prototype allocating fresh objects (GC-stress rooting)
const holeProto = Object.create(Array.prototype);
Object.defineProperty(holeProto, "0", {
    get() {
        return { tag: "alloc-" + [1, 2, 3].join("-") };
    },
});
const sparse = new Array(2);
Object.setPrototypeOf(sparse, holeProto);
sparse[1] = "tail";
print("sparse hole getter:", JSON.stringify(sparse));

// 4. JSON.stringify replacer Proxy with allocating traps and deduplication
let trapCount = 0;
const allocReplacer = new Proxy(["b", new Number(1), new String("a"), "b"], {
    get(target, key, receiver) {
        trapCount++;
        const _tmp = { k: String(key), n: trapCount };
        return Reflect.get(target, key, receiver);
    },
});
print("alloc proxy replacer:", JSON.stringify({ a: 1, b: 2, 1: 3, c: 4 }, allocReplacer));
