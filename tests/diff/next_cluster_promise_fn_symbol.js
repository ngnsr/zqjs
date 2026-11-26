// Regression diff test for Promise, Function, Symbol, and deletable builtin globals.

// 1. Function.prototype is callable and returns undefined.
print("fn_proto_typeof:", typeof Function.prototype);
print("fn_proto_call:", Function.prototype(), Function.prototype(1, 2));

// 2. Symbol has [[Construct]] (isConstructor) while `new Symbol()` throws TypeError.
const symObj = Reflect.construct(function () {}, [], Symbol);
print("sym_is_ctor:", Object.getPrototypeOf(symObj) === Symbol.prototype);
let newSymThrew = false;
try {
  new Symbol();
} catch (e) {
  newSymThrew = e instanceof TypeError;
}
print("new_sym_throws:", newSymThrew);

// 3. GetFunctionRealm throws TypeError on revoked proxy when prototype is non-object.
const rev = Proxy.revocable(function () {}, {
  get() {
    rev.revoke();
  },
});
let revokedThrew = false;
try {
  new rev.proxy();
} catch (e) {
  revokedThrew = e instanceof TypeError;
}
print("revoked_proxy_ctor:", revokedThrew);

// 4. Builtin globals are deletable (except non-configurable undefined/NaN/Infinity).
print("del_const:", delete globalThis.undefined, delete globalThis.NaN);
print("del_weakset:", delete globalThis.WeakSet, "WeakSet" in globalThis);
globalThis.WeakSet = 123;
print("reassigned_weakset:", globalThis.WeakSet, delete globalThis.WeakSet, "WeakSet" in globalThis);

// 5. Promise.try resolves return values and rejects thrown errors.
Promise.try(() => 42).then((v) => print("try_resolve:", v));
Promise.try(() => {
  throw "boom";
}).catch((e) => print("try_reject:", e));

// 6. Promise.prototype.finally subclass constructor call count.
let count = 0;
class CountPromise extends Promise {
  constructor(executor) {
    count++;
    super(executor);
  }
}
new CountPromise((r) => r())
  .finally(() => {})
  .then(() => {
    print("finally_subclass_count:", count);
  });
