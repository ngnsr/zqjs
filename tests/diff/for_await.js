// for await (M38, D68): async/sync/custom iterables, AsyncIteratorClose, tick order
const log = [];
function errName(e) {
  return e instanceof TypeError ? "TypeError" : String(e);
}

async function* gen(n) {
  try {
    for (let i = 1; i <= n; i++) yield i;
  } finally {
    log.push("gen finally");
  }
}

function customIter(values, opts) {
  let i = 0;
  return {
    [Symbol.asyncIterator]() { return this; },
    next() {
      log.push("next");
      if (opts && opts.bad) return Promise.resolve(42);
      return Promise.resolve(i < values.length ? { value: values[i++], done: false } : { value: "end", done: true });
    },
    return() {
      log.push("return called");
      if (opts && opts.badReturn) return Promise.resolve("not an object");
      if (opts && opts.rejectReturn) return Promise.reject("return rejected");
      return new Promise((res) => Promise.resolve().then(() => { log.push("return settled"); res({ done: true }); }));
    },
  };
}

(async () => {
  const out = [];
  // async generator, arrays of promises, sync iterables (async-from-sync), custom async iterators
  for await (const v of gen(3)) out.push(v);
  for await (const v of [Promise.resolve("p1"), "plain", Promise.resolve("p2")]) out.push(v);
  for await (const v of new Set(["s1", "s2"])) out.push(v);
  for await (const ch of "ab") out.push(ch);
  for await (const v of customIter(["c1", "c2"])) out.push(v);
  print("sources:", out.join(","));

  // break / return / throw → return() called and awaited, generator finally runs
  for await (const v of gen(5)) {
    if (v === 2) break;
  }
  log.push("after break");
  const found = await (async () => {
    for await (const v of customIter(["x", "y", "z"])) {
      if (v === "y") return "returned " + v;
    }
  })();
  log.push(found);
  try {
    for await (const v of gen(3)) {
      throw new Error("body threw at " + v);
    }
  } catch (e) {
    log.push("caught " + e.message);
  }
  outer: for (const k of [1, 2]) {
    for await (const v of customIter(["o1", "o2"])) {
      if (k === 1) continue outer;
      break outer;
    }
  }
  log.push("after labeled jumps");
  print("closes:", log.splice(0).join(" | "));

  // non-object results and bad return() results → TypeError
  const errs = [];
  try { for await (const v of customIter([], { bad: true })) errs.push(v); } catch (e) { errs.push("next: " + errName(e)); }
  try { for await (const v of customIter([1], { badReturn: true })) break; } catch (e) { errs.push("return: " + errName(e)); }
  try { for await (const v of customIter([1], { rejectReturn: true })) break; } catch (e) { errs.push("return: " + errName(e)); }
  try {
    for await (const v of customIter([1], { badReturn: true })) throw "original";
  } catch (e) { errs.push("throw wins: " + errName(e)); }
  try {
    for await (const v of customIter([1], { rejectReturn: true })) throw "original2";
  } catch (e) { errs.push("throw wins: " + errName(e)); }
  try { for await (const v of 5) errs.push(v); } catch (e) { errs.push("not iterable: " + errName(e)); }
  try { for await (const v of [Promise.reject("rej elem"), 2]) errs.push(v); } catch (e) { errs.push("element: " + e); }
  print("errors:", errs.join(" | "), "/", log.splice(0).join(" | "));

  // destructuring heads, var/let/assignment targets, partial destructuring closes
  const pairs = [];
  for await (const [a, b] of [[1, 2], Promise.resolve([3, 4])]) pairs.push(a + b);
  for await (let { x, y = "dflt" } of [{ x: "X" }]) pairs.push(x + y);
  let vv;
  for await (vv of gen(2)) pairs.push("v" + vv);
  const target = {};
  for await (target.prop of ["t"]) pairs.push(target.prop);
  let w;
  for await ([w] of [["arr"]]) pairs.push(w);
  try {
    for await (const { z } of customIter([null])) pairs.push(z);
  } catch (e) { pairs.push("destructure " + errName(e)); }
  print("heads:", pairs.join(","), "/", log.splice(0).join(" | "));

  // nested for await
  const nest = [];
  for await (const a of gen(2)) {
    for await (const b of [Promise.resolve("x"), "y"]) nest.push(a + b);
  }
  print("nested:", nest.join(","), log.splice(0).length);

  // closure capture per iteration
  const fns = [];
  for await (const v of [1, 2, 3]) fns.push(() => v);
  print("per-iteration:", fns.map((f) => f()).join(","));
})();

// sync iterator closed when a yielded promise rejects (async-from-sync)
(async () => {
  const closes = [];
  const it = {
    i: 0,
    [Symbol.iterator]() { return this; },
    next() { this.i++; return { value: this.i === 2 ? Promise.reject("second") : this.i, done: false }; },
    return() { closes.push("sync return"); return {}; },
  };
  try {
    for await (const v of it) closes.push(v);
  } catch (e) {
    closes.push("caught " + e);
  }
  print("async-from-sync:", closes.join(","));
})();

// tick ordering against a parallel promise chain
(async () => {
  const order = [];
  const done = (async () => {
    for await (const v of [1, Promise.resolve(2)]) order.push("fa" + v);
    for await (const v of gen(2)) order.push("g" + v);
    order.push("loop done");
  })();
  let p = Promise.resolve();
  for (let i = 1; i <= 12; i++) p = p.then(() => order.push("t" + i));
  await p;
  await done;
  print("ticks:", order.join(" "));
})();
