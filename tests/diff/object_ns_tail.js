// Node-differential regression tests for Array.length coercion order on set
// and TypedArray out-of-bounds [[Set]] when receiver is in prototype chain.

// 1. Array.length coercion order on set (strict assignment & Reflect.set)
{
  const arr = [1, 2, 3];
  const hints = [];
  const lenObj = {
    [Symbol.toPrimitive](hint) {
      hints.push(hint);
      Object.defineProperty(arr, "length", { writable: false });
      return 0;
    },
  };
  let errName = "none";
  try {
    (function () {
      "use strict";
      arr.length = lenObj;
    })();
  } catch (e) {
    errName = e.name;
  }
  print("strict set:", errName, hints.join(","), arr.length);
}

{
  const arr = [1, 2, 3];
  const hints = [];
  const lenObj = {
    [Symbol.toPrimitive](hint) {
      hints.push(hint);
      Object.defineProperty(arr, "length", { writable: false });
      return 0;
    },
  };
  const ok = Reflect.set(arr, "length", lenObj);
  print("reflect set:", ok, hints.join(","), arr.length);
}

{
  // Same length when non-writable after first coercion succeeds
  const arr = [1, 2, 3];
  const hints = [];
  const lenObj = {
    [Symbol.toPrimitive](hint) {
      hints.push(hint);
      Object.defineProperty(arr, "length", { writable: false });
      return 3;
    },
  };
  const ok = Reflect.set(arr, "length", lenObj);
  print("same len:", ok, hints.join(","), arr.length);
}

// 2. TypedArray OOB [[Set]] when receiver is in the prototype chain
{
  const ta = new Int32Array(4);
  const child = Object.create(ta);
  let calls = 0;
  const v = {
    valueOf() {
      calls++;
      return 7;
    },
  };
  const ok = Reflect.set(child, 100, v, ta);
  print("ta oob proto=receiver:", ok, calls);
}

{
  const bta = new BigInt64Array(4);
  const child = Object.create(bta);
  let calls = 0;
  const v = {
    valueOf() {
      calls++;
      return 9n;
    },
  };
  const ok = Reflect.set(child, 100, v, bta);
  print("bigint ta oob proto=receiver:", ok, calls);
}
