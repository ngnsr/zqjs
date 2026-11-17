const order = [];

// 1. Promise.all: out-of-order resolution + non-promise values
let r1 = null;
let r2 = null;
const p1 = new Promise(function (r) { r1 = r; });
const p2 = new Promise(function (r) { r2 = r; });
Promise.all([p1, 99, p2]).then(function (arr) {
  order.push("all_ok:" + arr.join(","));
});
r2("two");
r1("one");

// 2. Promise.all: rejection short-circuits
let rNever = null;
const pNever = new Promise(function (r) { rNever = r; });
Promise.all([pNever, Promise.reject("boom"), Promise.resolve(1)]).catch(function (e) {
  order.push("all_rej:" + e);
});

// 3. Promise.allSettled: mixed fulfilled, rejected, non-promise, out-of-order
let s1 = null;
let s2 = null;
const ps1 = new Promise(function (_, rej) { s1 = rej; });
const ps2 = new Promise(function (res) { s2 = res; });
Promise.allSettled([ps1, "lit", ps2]).then(function (res) {
  const parts = [];
  for (let i = 0; i < res.length; i++) {
    const item = res[i];
    if (item.status === "fulfilled") parts.push("F:" + item.value);
    else parts.push("R:" + item.reason);
  }
  order.push("settled:" + parts.join(","));
});
s2("ok2");
s1("err1");

// 4. Promise.race: first settled wins (fulfill vs reject, and non-promise)
let rc1 = null;
let rc2 = null;
const pr1 = new Promise(function (r) { rc1 = r; });
const pr2 = new Promise(function (_, rej) { rc2 = rej; });
Promise.race([pr1, pr2]).then(function (v) {
  order.push("race_win:" + v);
}, function (e) {
  order.push("race_rej:" + e);
});
rc2("fast_err");
rc1("slow_ok");

Promise.race([7, Promise.reject("later")]).then(function (v) {
  order.push("race_nonp:" + v);
});

// 5. Promise.any: ignores earlier rejection, picks first fulfillment
let a1 = null;
let a2 = null;
const pa1 = new Promise(function (_, rej) { a1 = rej; });
const pa2 = new Promise(function (res) { a2 = res; });
Promise.any([pa1, pa2]).then(function (v) {
  order.push("any_win:" + v);
});
a1("e1");
a2("winner");

// 6. Promise.any: all reject -> AggregateError with errors in input order
let ar1 = null;
let ar2 = null;
const par1 = new Promise(function (_, rej) { ar1 = rej; });
const par2 = new Promise(function (_, rej) { ar2 = rej; });
Promise.any([par1, par2]).catch(function (e) {
  order.push("any_all_rej:" + e.name + ":" + e.errors.join(","));
});
ar2("second_err");
ar1("first_err");

// 7. Empty iterables
Promise.all([]).then(function (v) { order.push("all_empty:" + v.length); });
Promise.allSettled([]).then(function (v) { order.push("settled_empty:" + v.length); });
Promise.any([]).catch(function (e) { order.push("any_empty:" + e.name + ":" + e.errors.length); });
let raceEmptySettled = false;
Promise.race([]).then(function () { raceEmptySettled = true; }, function () { raceEmptySettled = true; });

// 8. Non-iterable arguments reject asynchronously with TypeError (do not throw synchronously)
Promise.all(123).catch(function (e) { order.push("all_nonit:" + e.name); });
Promise.allSettled(null).catch(function (e) { order.push("settled_nonit:" + e.name); });
Promise.race(undefined).catch(function (e) { order.push("race_nonit:" + e.name); });
Promise.any(false).catch(function (e) { order.push("any_nonit:" + e.name); });

// 9. String & Set iterables
Promise.all(new Set([10, 20])).then(function (v) { order.push("all_set:" + v.join(",")); });
Promise.all("ab").then(function (v) { order.push("all_str:" + v.join(",")); });

// 10. Interleaving ticks & final print
Promise.resolve().then(function () {
  order.push("tick1");
}).then(function () {
  order.push("tick2");
}).then(function () {
  order.push("tick3");
}).then(function () {
  order.push("race_empty_settled=" + raceEmptySettled);
  print(order.join("|"));
});
