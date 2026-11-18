// Basic async/await: values, promises, recursion, arrows, methods, Promise.all, new
async function nonPromise() {
  const a = await 42;
  const b = await "ok";
  const c = await undefined;
  return a + ":" + b + ":" + String(c);
}
nonPromise().then(v => print("nonPromise:", v));

async function settled() {
  const a = await Promise.resolve(10);
  let resolvePending = null;
  const p = new Promise(r => { resolvePending = r; });
  Promise.resolve().then(() => resolvePending(20));
  const b = await p;
  return a + b;
}
settled().then(v => print("settled:", v));

async function fact(n) {
  if (n <= 1) return 1;
  return n * await fact(n - 1);
}
fact(5).then(v => print("fact:", v));

const arr1 = async x => await (x + 1);
const arr2 = async (a, b) => await a + await b;
const arr3 = async () => { return await 99; };
const arr4 = async (a = 5, ...rest) => await a + rest.length;
const arr5 = async ({ x }, [y]) => await x + await y;

Promise.all([
  arr1(10),
  arr2(3, 4),
  arr3(),
  arr4(undefined, 1, 2),
  arr5({ x: 7 }, [8]),
]).then(res => print("arrows:", res.join(",")));

const obj = {
  base: 100,
  async add(x) {
    return this.base + await x;
  },
};
obj.add(23).then(v => print("method:", v));

Promise.all([1, 2, 3].map(async x => await (x * 10)))
  .then(res => print("map:", res.join(",")));

async function notCtor() {}
try {
  new notCtor();
  print("new: unexpected");
} catch (e) {
  print("new:", e.name);
}
