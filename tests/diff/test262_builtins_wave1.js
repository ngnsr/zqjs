// Test262 Wave 1 regression coverage across Function, ThrowTypeError, Object,
// Proxy/Reflect, Array, Array.fromAsync, RegExp, and String built-ins.

// 1. %ThrowTypeError% and Function.prototype metadata
(() => {
  const fnProto = Function.prototype;
  print("fnProto.name:", JSON.stringify(fnProto.name), "toString:", Object.prototype.toString.call(fnProto));
  const protoNames = Object.getOwnPropertyNames(fnProto);
  print("fnProto.hasName:", protoNames.includes("name"), "hasLength:", protoNames.includes("length"));

  const dCaller = Object.getOwnPropertyDescriptor(fnProto, "caller");
  const dArgs = Object.getOwnPropertyDescriptor(fnProto, "arguments");
  const strictFn = function () {
    "use strict";
    return Object.getOwnPropertyDescriptor(arguments, "callee");
  };
  const defaultParamFn = function (a = 1) {
    return Object.getOwnPropertyDescriptor(arguments, "callee");
  };
  const dStrict = strictFn();
  const dDefault = defaultParamFn();
  const tte = dStrict.get;
  print(
    "tte callee identity:",
    dStrict.get === dStrict.set,
    dDefault.get === tte,
    dDefault.set === tte,
    dCaller.configurable,
    dCaller.enumerable,
    dArgs.configurable,
    dArgs.enumerable
  );
  print("tte frozen:", Object.isFrozen(tte), Object.isExtensible(tte), Object.getOwnPropertyNames(tte).join(","));
  for (const fn of [tte, dCaller.get, dCaller.set, dArgs.get, dArgs.set]) {
    try {
      fn();
      print("tte call: no throw");
    } catch (e) {
      print("tte call:", e.name);
    }
  }
})();

// 2. Function.prototype.bind: length, name, custom prototype
(() => {
  const base = function (a, b, c) {
    return (this ? this.v : 0) + (a || 0) + (b || 0);
  };
  Object.defineProperty(base, "length", { value: 1e6, configurable: true });
  const b1 = base.bind({ v: 10 }, 5);
  print("bind huge len:", b1.length, b1(2));

  Object.defineProperty(base, "length", { value: Infinity, configurable: true });
  print("bind inf len:", base.bind(null, 1).length);

  Object.defineProperty(base, "length", { value: -3.7, configurable: true });
  print("bind neg len:", base.bind(null).length);

  Object.defineProperty(base, "length", { value: NaN, configurable: true });
  print("bind nan len:", base.bind(null).length);

  Object.defineProperty(base, "name", { value: "customBase", configurable: true });
  const b2 = base.bind(null);
  print("bind name:", b2.name, b2.bind(null).name);

  const customProto = { tag: "protoTag" };
  Object.setPrototypeOf(base, customProto);
  const b3 = Function.prototype.bind.call(base, null);
  print("bind proto:", Object.getPrototypeOf(b3) === customProto, b3.tag);
})();

// 3. Function.prototype.apply with sparse array & holes
(() => {
  const collect = function (a, b, c) {
    return [a, b, c];
  };
  const sparse = [1, , 3];
  Object.defineProperty(Array.prototype, 1, {
    value: 99,
    configurable: true,
    writable: true,
  });
  print("apply sparse:", JSON.stringify(collect.apply(null, sparse)));
  delete Array.prototype[1];
})();

// 4. Object / Proxy / Reflect conformance
(() => {
  const revArr = Proxy.revocable([], {});
  print("proxy toString arr:", Object.prototype.toString.call(revArr.proxy));
  revArr.revoke();
  try {
    Object.prototype.toString.call(revArr.proxy);
    print("revoked toString: no throw");
  } catch (e) {
    print("revoked toString:", e.name);
  }

  const revTarget = Proxy.revocable({}, {});
  const revHandler = Proxy.revocable({}, {});
  revTarget.revoke();
  revHandler.revoke();
  const wrappedRevTarget = new Proxy(revTarget.proxy, {});
  const wrappedRevHandler = new Proxy({}, revHandler.proxy);
  print("wrapped revoked created:", typeof wrappedRevTarget, typeof wrappedRevHandler);

  const callProxy = new Proxy(function () {}, {});
  print("proxy toString fn:", Object.prototype.toString.call(callProxy));

  let protoTrapCalls = 0;
  const protoProxy = new Proxy({}, {
    getPrototypeOf() {
      protoTrapCalls++;
      return null;
    },
  });
  const plain = {};
  Object.setPrototypeOf(plain, protoProxy);
  print("setProto proxy cycle:", protoTrapCalls, Object.getPrototypeOf(plain) === protoProxy);
  print("setProto Object.prototype null:", Object.setPrototypeOf(Object.prototype, null) === Object.prototype);
  try {
    Object.setPrototypeOf(Object.prototype, {});
    print("setProto Object.prototype {}: no throw");
  } catch (e) {
    print("setProto Object.prototype {}:", e.name);
  }

  const sealedTarget = {};
  Object.defineProperty(sealedTarget, "a", { value: 1, writable: false, configurable: false, enumerable: true });
  Object.preventExtensions(sealedTarget);
  const integrityProxy = new Proxy(sealedTarget, {});
  print("proxy integrity:", Object.isSealed(integrityProxy), Object.isFrozen(integrityProxy));
  Object.freeze(integrityProxy);
  print("proxy freeze:", Object.isFrozen(sealedTarget));

  const strDescs = Object.getOwnPropertyDescriptors("ab");
  print("strDescs:", strDescs[0].value, strDescs[1].value, strDescs.length.value, strDescs.length.writable);

  const arrNamed = [10, 20];
  arrNamed.z = 1;
  arrNamed.a = 2;
  print("arr names:", Object.getOwnPropertyNames(arrNamed).join(","));

  const strWrap = new String("hi");
  strWrap.b = 1;
  print("str names:", Object.getOwnPropertyNames(strWrap).join(","));

  const orderedFn = function () {};
  orderedFn[2] = "two";
  orderedFn[0] = "zero";
  print("fn names:", Object.getOwnPropertyNames(orderedFn).join(","));

  const mutObj = {
    get a() {
      delete this.b;
      this.c = 99;
      return 1;
    },
    b: 2,
    c: 3,
  };
  print("entries getter mut:", JSON.stringify(Object.entries(mutObj)));
  print("values getter mut:", JSON.stringify(Object.values({ get a() { this.b = 42; return 1; }, b: 2 })));
})();

// 5. Array sparse/generic/species/length edge cases
{
  const customCtor = function (len) {
    const o = { length: len };
    Object.preventExtensions(o);
    return o;
  };
  const spArr = [1, 2];
  spArr.constructor = { [Symbol.species]: customCtor };
  for (const op of [
    () => spArr.slice(0),
    () => spArr.splice(0, 1),
    () => spArr.flat(),
    () => spArr.flatMap((x) => [x]),
  ]) {
    try {
      op();
      print("species non-ext: no throw");
    } catch (e) {
      print("species non-ext:", e.name);
    }
  }

  print("slice start>end:", JSON.stringify([1, 2, 3].slice(2, 1)));

  const generic = { length: 2, 0: "a", 1: ["b", "c"] };
  print("generic flat:", JSON.stringify(Array.prototype.flat.call(generic)));
  print("generic flatMap:", JSON.stringify(Array.prototype.flatMap.call(generic, (x) => [x, "!"])));

  const spreadProxy = new Proxy(["x", "y"], {});
  print("concat proxy:", JSON.stringify(["start"].concat(spreadProxy)));

  const shrinkIdx = [10, 20, 30];
  Object.defineProperty(Array.prototype, 2, {
    get() {
      return 300;
    },
    configurable: true,
  });
  print(
    "indexOf shrink:",
    shrinkIdx.indexOf(300, {
      valueOf() {
        shrinkIdx.length = 0;
        return 0;
      },
    })
  );
  const shrinkLast = [10, 20, 30];
  print(
    "lastIndexOf shrink:",
    shrinkLast.lastIndexOf(300, {
      valueOf() {
        shrinkLast.length = 0;
        return 2;
      },
    })
  );
  delete Array.prototype[2];

  // copyWithin on Proxy without skipping from == to trap/checks
  let getCount = 0;
  const cwProxy = new Proxy({ length: 2, 0: "a", 1: "b" }, {
    get(t, k, r) {
      if (k === "0") getCount++;
      return Reflect.get(t, k, r);
    },
  });
  Array.prototype.copyWithin.call(cwProxy, 0, 0);
  print("copyWithin same idx gets:", getCount);

  // Sparse pop/shift/reverse/sort/toSorted/toSpliced/with
  const pArr = [1, , ,];
  Object.defineProperty(Array.prototype, 2, { value: 222, configurable: true, writable: true });
  print("sparse pop:", pArr.pop(), pArr.length);
  const revSparse = [1, , 3];
  revSparse.reverse();
  print("sparse reverse:", 0 in revSparse, revSparse[0], 1 in revSparse, 2 in revSparse, revSparse[2]);
  print("toSorted hole:", JSON.stringify([2, , 1].toSorted()));
  print("toSpliced hole:", JSON.stringify([1, , 3].toSpliced(1, 0, 9)));
  print("with hole:", JSON.stringify([1, , 3].with(0, 7)));
  delete Array.prototype[2];

  // Large index keys > 2^32 - 1 on array-like push/pop
  const bigLike = { length: 4294967294 };
  Array.prototype.push.call(bigLike, "a", "b");
  print("big push:", bigLike.length, bigLike[4294967294], bigLike[4294967295]);
  print("big pop:", Array.prototype.pop.call(bigLike), bigLike.length, 4294967295 in bigLike);

  // Array.length double valueOf coercion and trailing hole non-configurable shrink
  let lenCoerceCount = 0;
  const lenArr = [1, , ];
  Object.seal(lenArr);
  Object.defineProperty(lenArr, "length", {
    value: {
      valueOf() {
        lenCoerceCount++;
        return 1;
      },
    },
    writable: false,
  });
  print("len coerce count:", lenCoerceCount, lenArr.length);
  try {
    Object.defineProperty(lenArr, "length", { value: 0 });
    print("shrink non-conf: no throw");
  } catch (e) {
    print("shrink non-conf:", e.name, lenArr.length);
  }
}

// 6. RegExp & String Symbol.match checks
{
  print("rx lengths:", RegExp.prototype.exec.length, RegExp.prototype.test.length);
  const rxLike = { [Symbol.match]: true, source: "a+", flags: "i" };
  const built = new RegExp(rxLike);
  print("new RegExp(rxLike):", built.source, built.flags, built.test("AAA"));
  print("RegExp(rxLike) short:", RegExp({ [Symbol.match]: true, constructor: RegExp }) !== undefined);

  const rxNonW = /a/g;
  Object.defineProperty(rxNonW, "lastIndex", { value: 0, writable: false });
  for (const op of [() => rxNonW.exec("a"), () => rxNonW.test("a")]) {
    try {
      op();
      print("non-writable lastIndex: no throw");
    } catch (e) {
      print("non-writable lastIndex:", e.name);
    }
  }

  print("Sym.match null flags:", JSON.stringify(RegExp.prototype[Symbol.match].call({ exec() { return null; }, flags: null }, "x")));

  const fakeRx = { [Symbol.match]: true, toString() { return "a"; } };
  for (const op of [
    () => "abc".includes(fakeRx),
    () => "abc".startsWith(fakeRx),
    () => "abc".endsWith(fakeRx),
    () => "abc".replaceAll(fakeRx, "b"),
    () => "abc".matchAll(fakeRx),
  ]) {
    try {
      op();
      print("isRegExp throw: no throw");
    } catch (e) {
      print("isRegExp throw:", e.name);
    }
  }
  const nonRx = /a/;
  nonRx[Symbol.match] = false;
  print("re with match=false:", "/a/".includes(nonRx), "/a/".startsWith(nonRx));
}

// 7. Array.fromAsync (microtasks drained by harness)
{
  const asyncIter = {
    [Symbol.asyncIterator]() {
      let i = 0;
      return {
        async next() {
          if (i < 3) return { value: (i++) + 1, done: false };
          return { value: undefined, done: true };
        },
      };
    },
  };
  Array.fromAsync(asyncIter, (x) => x * 10).then((res) => {
    print("fromAsync iter:", JSON.stringify(res));
  });

  let closedAsync = 0;
  const throwingAsyncIter = {
    [Symbol.asyncIterator]() {
      return {
        async next() { return { value: 1, done: false }; },
        async return() { closedAsync++; return { done: true }; },
      };
    },
  };
  Array.fromAsync(throwingAsyncIter, () => {
    throw new RangeError("boom");
  }).catch((e) => {
    print("fromAsync close on err:", e.name, closedAsync);
  });
}
