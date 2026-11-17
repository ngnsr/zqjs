// Basic arrow forms & IIFE
const id = x => x;
const parens = (x) => x + 1;
const zero = () => 42;
const add = (a, b) => a + b;
const blockRet = (a, b) => {
  const s = a + b;
  return s * 2;
};
const blockUndef = x => {
  const y = x + 1;
};
print(id(7), parens(7), zero(), add(3, 4), blockRet(3, 4), blockUndef(5));
print((x => x * 2)(21));

// Object-literal body
const makeObj = (k, v) => ({ key: k, val: v });
const o = makeObj("a", 99);
print(o.key, o.val);

// Closures and mutable captures
const makeCounter = start => {
  let n = start;
  return () => {
    n += 1;
    return n;
  };
};
const c1 = makeCounter(10);
const c2 = makeCounter(100);
print(c1(), c1(), c2(), c1());

// Per-iteration let capture in loops
const fns = [];
for (let i = 0; i < 4; i++) {
  fns.push(() => i * 10);
}
print(fns[0](), fns[1](), fns[2](), fns[3]());

// Nested arrows (currying)
const curry = a => b => c => a + b * c;
print(curry(1)(2)(3));

// Recursion through an outer binding
const fact = n => n <= 1 ? 1 : n * fact(n - 1);
print(fact(6));

// Array map / filter / reduce / forEach
const nums = [1, 2, 3, 4, 5, 6];
const evens = nums.filter(n => n % 2 === 0);
const doubled = evens.map(n => n * 2);
const sum = doubled.reduce((acc, n) => acc + n, 0);
print(evens.join(","), doubled.join(","), sum);
let eachOut = "";
nums.forEach((n, i) => { eachOut += i + ":" + n + " "; });
print(eachOut);

// Map / Set forEach
const m = new Map([["x", 1], ["y", 2]]);
m.forEach((v, k) => print("map", k, v));
const s = new Set([10, 20]);
s.forEach(v => print("set", v));

// new on an arrow throws TypeError
const Arrow = x => ({ x: x });
try {
  new Arrow(1);
  print("should not reach");
} catch (e) {
  print("new arrow:", e.name);
}

// Promise then / catch / finally / all chains
Promise.resolve(10)
  .then(v => v + 5)
  .then(v => {
    if (v === 15) throw "err15";
    return v;
  })
  .catch(e => "caught:" + e)
  .finally(() => print("finally ran"))
  .then(v => Promise.all([Promise.resolve(v), Promise.resolve("!")] ))
  .then(arr => print("promise:", arr.join("")));
