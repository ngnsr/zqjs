// Promise() without new throws TypeError
try {
  Promise(function () {});
} catch (e) {
  print("noNew", e.name);
}

// Non-callable executor throws TypeError
try {
  new Promise(123);
} catch (e) {
  print("nonFn", e.name);
}

// Executor receives callable resolve and reject; double-settle is ignored
let savedRes = null;
const p1 = new Promise(function (resolve, reject) {
  savedRes = resolve;
  resolve(42);
  reject("ignored");
  resolve(99);
});
print("sameAfter", Promise.resolve(p1) === p1);
savedRes(100);

// Executor throw after resolve does not overwrite settlement
const p2 = new Promise(function (resolve) {
  resolve("ok");
  throw "late-throw";
});
print("lateThrow", Promise.resolve(p2) === p2);

// Promise.resolve wraps non-Promise values into a Promise
const p3 = Promise.resolve({ v: 7 });
print("wrapped", p3 !== p1, Promise.resolve(p3) === p3, Object.getPrototypeOf(p3) === Object.getPrototypeOf(p1));
