// 1. Synchronous code finishes before microtasks run
const order = [];
Promise.resolve(1).then(function (v) {
  order.push("then1:" + v);
  return v + 1;
}).then(function (v) {
  order.push("then2:" + v);
});
order.push("sync");

// 2. Multiple .then() on one pending Promise + FIFO interleaving
let resA = null;
const pA = new Promise(function (r) { resA = r; });
pA.then(function (v) { order.push("A1:" + v); });
pA.then(function (v) { order.push("A2:" + v); });
resA("ok");

// 3. Pass-through non-callable handlers & rejection recovery via .catch
Promise.resolve(10)
  .then(123)
  .then(function (v) { return v * 2; })
  .then(function (v) {
    order.push("pass:" + v);
    throw "boom";
  })
  .then(function () {
    order.push("unreachable");
  })
  .catch(function (e) {
    order.push("caught:" + e);
    return "recovered";
  })
  .then(function (v) {
    order.push("after:" + v);
  });

// 4. .then returning a pending native Promise (adoption)
let resInner = null;
const inner = new Promise(function (r) { resInner = r; });
Promise.resolve("start").then(function () {
  return inner;
}).then(function (v) {
  order.push("adopted:" + v);
});
resInner(99);

// 5. Self-resolution inside .then rejects with TypeError
let selfP = null;
selfP = Promise.resolve(1).then(function () {
  return selfP;
});
selfP.catch(function (e) {
  order.push("self:" + e.name);
});

// 6. Final flush check (runs after all earlier microtasks)
Promise.resolve().then(function () {
  return Promise.resolve().then(function () {
    return Promise.resolve();
  });
}).then(function () {
  print(order.join("|"));
});
