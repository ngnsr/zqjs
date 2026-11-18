// Microtask ordering: await vs .then chains, returning a promise (2-step adoption)
const order = [];

async function f1() {
  order.push("f1:start");
  const x = await 1;
  order.push("f1:after1:" + x);
  const y = await Promise.resolve(2);
  order.push("f1:after2:" + y);
  return "f1:done";
}

async function f2() {
  order.push("f2:start");
  return Promise.resolve("adopted");
}

f1().then(v => order.push("then:f1:" + v));
f2().then(v => order.push("then:f2:" + v));

Promise.resolve()
  .then(() => order.push("tick1"))
  .then(() => order.push("tick2"))
  .then(() => order.push("tick3"))
  .then(() => order.push("tick4"))
  .then(() => print(order.join("|")));

order.push("sync:end");
