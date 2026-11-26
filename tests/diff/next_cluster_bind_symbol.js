// Regression diff test for Function.prototype.bind and Symbol builtins.

const boundFn = (function (a, b, c) {
  return [this, a, b, c].join(",");
}).bind("ctx", 1);
print("bind_call:", boundFn(2, 3));
print("bind_meta:", boundFn.length, boundFn.name);

const fFloat = function () {};
Object.defineProperty(fFloat, "length", { value: 3.9 });
print("bind_float_len:", fFloat.bind().length);

const fLarge = function () {};
Object.defineProperty(fLarge, "length", { value: 2147483648 });
print("bind_large_len:", fLarge.bind().length);

const sym = Symbol.for("zqjs.next.cluster");
print("symbol_ops:", Symbol.keyFor(sym), sym.description, typeof sym);
