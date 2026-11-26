// Conformance diff test for TypedArray constructors with callable object arguments
// (@@iterator lookup, non-callable @@iterator, throwing @@iterator getter, iterable & array-like functions).

function errName(fn) {
  try {
    fn();
    return "ok";
  } catch (e) {
    return e.name;
  }
}

// 1. Non-callable @@iterator on a function object throws TypeError (numeric & BigInt)
for (const bad of [{}, true, 42]) {
  const fnObj = function () {};
  fnObj[Symbol.iterator] = bad;
  print(
    "non-callable:",
    typeof bad,
    errName(() => new Uint8Array(fnObj)),
    errName(() => new Float64Array(fnObj)),
    errName(() => new BigInt64Array(fnObj)),
    errName(() => new BigUint64Array(fnObj))
  );
}

// 2. Throwing @@iterator getter on a function object propagates error
{
  const fnObj = function () {};
  Object.defineProperty(fnObj, Symbol.iterator, {
    get() {
      throw new RangeError("iter-boom");
    },
  });
  print(
    "throwing getter:",
    errName(() => new Int32Array(fnObj)),
    errName(() => new BigInt64Array(fnObj))
  );
}

// 3. Callable object with valid @@iterator populates TypedArray
{
  const fnIter = function (a, b) {};
  fnIter[Symbol.iterator] = function () {
    let i = 0;
    const vals = [10, 20, 30];
    return {
      next() {
        return i < vals.length ? { value: vals[i++], done: false } : { value: undefined, done: true };
      },
    };
  };
  const ta = new Int32Array(fnIter);
  print("iterable fn num:", ta.length, ta.join(","));

  const fnBigIter = function () {};
  fnBigIter[Symbol.iterator] = function* () {
    yield 1n;
    yield -2n;
    yield 3n;
  };
  const bta = new BigInt64Array(fnBigIter);
  print("iterable fn big:", bta.length, bta.join(","));
}

// 4. Callable object without @@iterator acts as array-like (uses function.length & indexed props)
{
  const fnLike = function (a, b) {};
  fnLike[0] = 7;
  fnLike[1] = 8;
  const ta = new Uint16Array(fnLike);
  print("array-like fn:", ta.length, ta.join(","));
}
