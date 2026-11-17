const order = [];

// 1. Fulfilled pass-through, 0 args check
Promise.resolve("val").finally(function (x) {
  order.push("fin1:arg=" + x);
  return "ignored";
}).then(function (v) {
  order.push("after1:" + v);
});

// 2. Rejected pass-through
Promise.reject("err").finally(function (x) {
  order.push("fin2:arg=" + x);
  return "ignored";
}).catch(function (e) {
  order.push("after2:" + e);
});

// 3. Non-callable onFinally passes through (fulfilled & rejected)
Promise.resolve(42).finally(123).then(function (v) {
  order.push("noncall_ok:" + v);
});
Promise.reject("bad").finally(null).catch(function (e) {
  order.push("noncall_err:" + e);
});

// 4. onFinally returning a pending promise delays settlement, still passes through original
let resPending = null;
const pendingFin = new Promise(function (r) { resPending = r; });
Promise.resolve("orig").finally(function () {
  order.push("fin4_start");
  return pendingFin;
}).then(function (v) {
  order.push("after4:" + v);
});
resPending("ignored_pending");

// 5. onFinally throwing overrides fulfillment & rejection
Promise.resolve("ok").finally(function () {
  throw "fin_throw";
}).catch(function (e) {
  order.push("override_throw_ok:" + e);
});

Promise.reject("orig_err").finally(function () {
  throw "new_err";
}).catch(function (e) {
  order.push("override_throw_err:" + e);
});

// 6. onFinally returning a rejected promise overrides fulfillment & rejection
Promise.resolve("ok2").finally(function () {
  return Promise.reject("fin_rej1");
}).catch(function (e) {
  order.push("override_rej_ok:" + e);
});

Promise.reject("orig_err2").finally(function () {
  return Promise.reject("fin_rej2");
}).catch(function (e) {
  order.push("override_rej_err:" + e);
});

// 7. Interleaving ticks
Promise.resolve().then(function () {
  order.push("tick1");
}).then(function () {
  order.push("tick2");
}).then(function () {
  order.push("tick3");
}).then(function () {
  order.push("tick4");
}).then(function () {
  order.push("tick5");
}).then(function () {
  print(order.join("|"));
});
