// Symbol.toPrimitive hints and return rules
const primObj = {
  [Symbol.toPrimitive](hint) {
    print("hint:" + hint);
    if (hint === "number") return 42;
    if (hint === "string") return "str";
    return "def";
  },
};
print(primObj + 1);
print(primObj - 2);
print(`${primObj}`);
print(String(primObj));
print(primObj < 50);
const mapObj = { def: 100, str: 200 };
print(mapObj[primObj]);

// Non-primitive return from [Symbol.toPrimitive] throws TypeError
try {
  ({ [Symbol.toPrimitive]() { return {}; } }) + 1;
} catch (e) {
  print("nonprim:", e.name);
}

// Non-callable [Symbol.toPrimitive] throws TypeError, null/undefined falls back
try {
  ({ [Symbol.toPrimitive]: 123 }) + 1;
} catch (e) {
  print("noncall:", e.name);
}
const nullPrim = {
  [Symbol.toPrimitive]: null,
  valueOf() { return 7; },
};
print(nullPrim + 3);

// Getter [Symbol.toPrimitive]
const getterPrim = {
  get [Symbol.toPrimitive]() {
    print("get toPrimitive");
    return (hint) => (hint === "string" ? "gstr" : 9);
  },
};
print(getterPrim + 1, `${getterPrim}`);

// OrdinaryToPrimitive order: + (.default -> valueOf, toString), -/< (.number -> valueOf, toString),
// template/String/key (.string -> toString, valueOf)
const both = {
  valueOf() { print("v"); return 10; },
  toString() { print("s"); return "20"; },
};
print("plus:", both + 1);
print("minus:", both - 1);
print("lt:", both < 15);
print("tpl:", `${both}`);
print("str:", String(both));
print("key:", ({ "20": "ok" })[both]);

// Fallback when first method returns object or is not callable
const fallback1 = {
  valueOf() { return {}; },
  toString() { return "99"; },
};
print(fallback1 + 1, fallback1 - 1);

const fallback2 = {
  toString: 123,
  valueOf() { return 55; },
};
print(`${fallback2}`);

// Both return object -> TypeError
try {
  ({ valueOf() { return {}; }, toString() { return {}; } }) + 1;
} catch (e) {
  print("bothobj:", e.name);
}

// Array.prototype.toString calls this.join
const arr = [1, 2, 3];
arr.join = function () { return "joined:" + this.length; };
print(String(arr), "" + arr);

arr.join = "not-fn";
print(String(arr));

// Evaluation order with side effects
const log = [];
const lhs = { valueOf() { log.push("L"); return 2; } };
const rhs = { valueOf() { log.push("R"); return 3; } };
print(lhs + rhs, log.join(","));
log.length = 0;
print(lhs < rhs, log.join(","));
log.length = 0;
print(lhs - rhs, log.join(","));

const target = {};
const keyObj = { toString() { log.push("K"); return "p"; } };
const valObj = { valueOf() { log.push("V"); return 4; } };
log.length = 0;
target[keyObj] = (log.push("E"), 77);
print(target.p, log.join(","));

// Exceptions inside toString / valueOf / join
try {
  ({ toString() { throw new RangeError("boom"); } }) + "";
} catch (e) {
  print("err1:", e.name, e.message);
}
try {
  const a = [1];
  a.join = () => { throw new TypeError("jboom"); };
  String(a);
} catch (e) {
  print("err2:", e.name, e.message);
}

// Functions with custom conversions
function fn1() {}
fn1[Symbol.toPrimitive] = (h) => "fn:" + h;
print(fn1 + 1, `${fn1}`);

function fn2() {}
fn2.valueOf = () => 12;
fn2.toString = () => "fn2";
print(fn2 + 3, `${fn2}`);
