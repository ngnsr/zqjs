function log(tag, v) {
    print(tag + ":", v);
    return v;
}

// null and undefined trigger fallback
print(null ?? "fallback");
print(undefined ?? "fallback");
print(null ?? undefined);
print(undefined ?? null);

// falsy values that are NOT nullish
print(0 ?? "fallback");
print(-0 ?? "fallback");
print("" ?? "fallback");
print(false ?? "fallback");
print(NaN ?? "fallback");
print({} ?? "fallback");
print([] ?? "fallback");

// short-circuiting: RHS only evaluated when LHS is null/undefined
print(log("lhs1", 0) ?? log("rhs1", 99));
print(log("lhs2", "") ?? log("rhs2", 99));
print(log("lhs3", false) ?? log("rhs3", 99));
print(log("lhs4", null) ?? log("rhs4", 99));
print(log("lhs5", undefined) ?? log("rhs5", 99));

// chaining (left-associative)
print(null ?? undefined ?? 42 ?? log("never", 1));
print(null ?? log("mid", 0) ?? log("never2", 1));

// mixing with || and && via parentheses
print((false || 0) ?? "x");
print((null || "") ?? "x");
print(null ?? (true && 7));
print(0 ?? (true && 7));

// precedence with bitwise, relational, arithmetic, conditional
print(0 | 0 ?? 5);
print(null ?? 1 | 2);
print((null ?? 1) + 2);
print(null ?? 1 + 2);
print(null ?? 1 ? "t" : "f");
print(undefined ?? 0 ? "t" : "f");

// inside templates and arrow bodies
const f = (x) => x ?? "default";
print(`val=${f(0)},${f(null)},${f(undefined)},${f("")}`);

// nested ?? with ?.
const obj = { a: { b: 0, c: "" }, n: null };
print(obj?.a?.b ?? 10);
print(obj?.a?.c ?? "x");
print(obj?.n?.x ?? "missing");
print((null)?.x ?? "after-null");
print(obj?.missing ?? obj?.a?.b ?? 99);
