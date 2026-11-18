const logs = [];
function tick(name, val) {
    logs.push(name);
    return val;
}

// 1. Basic property, computed, and call on null/undefined
const u = undefined;
const n = null;
print(u?.a, n?.a);
print(u?.[tick("no1", "k")], n?.[tick("no2", 0)]);
print(u?.(tick("no3", 1)), n?.(tick("no4", 2)));
print("logs1:", logs.length);

// 2. Long chains short-circuit the whole rest of the chain
print(u?.a.b.c.d);
print(n?.a[tick("no5", 0)].b(tick("no6", 1)).c);
print("logs2:", logs.length);

// 3. 0, "", false, NaN are NOT nullish
print(""?.length, "abc"?.charAt(1));
print((0)?.missing, (false)?.missing, (NaN)?.missing);

// 4. Parenthesised (a?.b).c ends the chain and throws on nullish
try {
    print((u?.a).b);
} catch (e) {
    print("paren-throw:", e.name);
}
const deep = { a: { b: { c: { d: 42 } } } };
print((deep?.a).b.c.d);
try {
    print(deep?.missing.b.c);
} catch (e) {
    print("nonopt-step-throw:", e.name);
}

// 5. Computed keys and evaluation order
const bag = { x: 10, y: 20 };
print(bag?.[tick("key1", "x")], bag?.[tick("key2", "y")]);
print("logs3:", logs.join(","));

// 6. Method calls keep `this`
const counter = {
    val: 100,
    get(delta) { return this.val + delta; },
    sub: {
        val: 200,
        get(delta) { return this.val + delta; }
    }
};
print(counter?.get(5));
print(counter.get?.(6));
print(counter?.get?.(7));
print(counter?.sub?.get(8));
print((counter.get)?.(9));
print(counter.missing?.(tick("no7", 1)));
print(counter?.missing?.(tick("no8", 2)));
print("logs4:", logs.length);

// Calling a non-nullish non-function still throws TypeError
try {
    print(counter?.val?.());
} catch (e) {
    print("call-nonfn:", e.name);
}

// 7. delete with optional chaining
const delObj = { a: 1, b: 2, sub: { c: 3 } };
print(delete u?.a, delete n?.[tick("no9", "x")], delete u?.a.b);
print(delete delObj?.a, "a" in delObj);
print(delete delObj?.[tick("delk", "b")], "b" in delObj);
print(delete delObj?.sub.c, "c" in delObj.sub);
try {
    print(delete delObj?.missing.x);
} catch (e) {
    print("delete-throw:", e.name);
}
print("logs5:", logs.join(","));

// 8. Arrays
const arr = [{ v: 11 }, null, { v: 33 }];
const nullArr = null;
print(arr?.[0]?.v, arr?.[1]?.v, arr?.[2]?.v, nullArr?.[tick("no10", 0)]);
print(arr?.push?.(4), arr.length);

// 9. Map.get?.()
const m = new Map([["k", 77]]);
const nullMap = null;
print(m?.get?.("k"), m.get?.("missing"), nullMap?.get?.("k"));

// 10. Inside templates and arrow bodies, nested ?? with ?., and a?.5:1
const fmt = (o) => `name=${o?.user?.name ?? "anon"}`;
print(fmt({ user: { name: "Ada" } }));
print(fmt({ user: null }));
print(fmt(null));

print(true?.5:1, false?.5:1);
