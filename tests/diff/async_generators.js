// Async generators (M38, D68): requests queue, implicit awaits, async yield*, tick order
const log = [];
function show(r) {
  return "{" + String(r.value) + "," + r.done + "}";
}
function errName(e) {
  return e instanceof TypeError ? "TypeError" : String(e);
}

// ---- declarations, expressions, methods, classes
async function* decl() { yield 1; yield 2; return 3; }
const expr = async function* named() { yield "e"; };
const obj = {
  async *m() { yield "m"; },
  async *["comp" + "uted"]() { yield "c"; },
};
class C {
  constructor() { this.base = 10; }
  async *items() { yield this.base; yield this.base + 1; }
  static async *range(a, b) { for (let i = a; i < b; i++) yield i; }
  #secret = 7;
  async *#priv() { yield this.#secret; }
  callPriv() { return this.#priv(); }
}
async function collect(it) {
  const out = [];
  for await (const v of it) out.push(v);
  return out.join(",");
}
(async () => {
  const c = new C();
  const parts = [await collect(decl()), await collect(expr()), await collect(obj.m()), await collect(obj.computed()),
    await collect(c.items()), await collect(C.range(2, 5)), await collect(c.callPriv())];
  print("forms:", parts.join(" / "), expr.name, obj.m.name);
})();

// ---- next before the first await; several next() queued without awaiting
async function* steps() {
  log.push("body start");
  const a = yield "y1";
  log.push("got " + a);
  const b = await Promise.resolve("awaited");
  log.push(b);
  const c2 = yield "y2";
  log.push("got " + c2);
  return "ret";
}
{
  const it = steps();
  log.push("created");
  const ps = [it.next("ignored"), it.next("A"), it.next("B"), it.next("C")];
  log.push("queued");
  ps.forEach((p, i) => p.then((r) => log.push("res" + i + " " + show(r))));
}

// ---- yield awaits its operand: fulfilled and rejected promises
async function* awaitsOperand() {
  yield Promise.resolve("resolved operand");
  try {
    yield Promise.reject(new Error("rejected operand"));
  } catch (e) {
    yield "caught " + e.message;
  }
  yield 5;
}
collect(awaitsOperand()).then((s) => print("yield operands:", s));

// ---- return(v) with a promise, through try/finally, yield inside finally
async function* withFinally() {
  try {
    yield 1;
    yield 2;
  } finally {
    log.push("finally runs");
    yield "from finally";
    log.push("after finally yield");
  }
}
(async () => {
  const it = withFinally();
  const out = [show(await it.next())];
  out.push(show(await it.return(Promise.resolve("R"))));
  out.push(show(await it.next()));
  out.push(show(await it.next()));
  print("return through finally:", out.join(" "));
})();

async function* finallyOverrides() {
  try {
    yield 1;
  } finally {
    return "finally wins";
  }
}
(async () => {
  const it = finallyOverrides();
  await it.next();
  print("finally return:", show(await it.return("ignored")));
})();

// return(rejected promise) at a yield: becomes a throw at that point
async function* catchesReturn() {
  try {
    yield 1;
  } catch (e) {
    yield "caught return rejection " + e;
  }
}
(async () => {
  const it = catchesReturn();
  await it.next();
  const r = await it.return(Promise.reject("bad"));
  print("return(rejected):", show(r), show(await it.next()));
})();

// ---- throw(e) caught inside
async function* catcher() {
  while (true) {
    try {
      yield "ready";
    } catch (e) {
      log.push("inside caught " + e);
    }
  }
}
(async () => {
  const it = catcher();
  await it.next();
  const r = await it.throw("boom");
  print("throw caught:", show(r));
  print("throw then return:", show(await it.return("done")));
})();

// ---- return/throw on suspendedStart and completed
(async () => {
  const out = [];
  const a = decl();
  out.push(show(await a.return("early")));
  out.push(show(await a.next()));
  const b = decl();
  try { await b.throw("early-throw"); } catch (e) { out.push("rejected " + e); }
  out.push(show(await b.next()));
  const c = decl();
  await collect(c);
  out.push(show(await c.next()));
  out.push(show(await c.return(Promise.resolve("after"))));
  try { await c.throw("after-throw"); } catch (e) { out.push("rejected " + e); }
  print("start/completed:", out.join(" "));
})();

// ---- queued return after completion (AwaitReturn), including a rejected promise
async function* short() { yield 1; }
(async () => {
  const it = short();
  const ps = [it.next(), it.next(), it.return(Promise.resolve("q1")), it.next(), it.return(Promise.reject("q2")), it.throw("q3"), it.next()];
  const out = [];
  for (const p of ps) {
    try { out.push(show(await p)); } catch (e) { out.push("rejected " + e); }
  }
  print("queued after completion:", out.join(" "));
})();

// ---- bad receivers: rejected promises, never a synchronous throw
(async () => {
  const proto = Object.getPrototypeOf(decl.prototype);
  const out = [];
  for (const recv of [undefined, {}, (function* () {})()]) {
    const p = proto.next.call(recv);
    out.push(p instanceof Promise);
    try { await p; } catch (e) { out.push(errName(e)); }
  }
  try { await proto.return.call(1, 2); } catch (e) { out.push(errName(e)); }
  try { await proto.throw.call(null, 2); } catch (e) { out.push(errName(e)); }
  print("bad receivers:", out.join(" "));
})();

// ---- async yield* over async generators, sync iterables, custom async iterators
async function* inner() {
  const x = yield "i1";
  log.push("inner got " + x);
  yield "i2";
  return "inner result";
}
async function* outer() {
  const r = yield* inner();
  yield "outer saw " + r;
  yield* [Promise.resolve("s1"), "s2"];
  const done = yield* { [Symbol.iterator]() { return [10, 20].values(); } };
  yield "sync done " + done;
}
(async () => {
  const it = outer();
  const out = [];
  let r = await it.next();
  while (!r.done) {
    out.push(r.value);
    r = await it.next("fed");
  }
  print("yield*:", out.join(","));
})();

function customAsync(label, withThrow, withReturn) {
  let i = 0;
  const it = {
    [Symbol.asyncIterator]() { return this; },
    next(v) {
      log.push(label + ".next(" + v + ")");
      i++;
      return Promise.resolve({ value: label + i, done: i > 2 });
    },
  };
  if (withThrow) it.throw = (e) => { log.push(label + ".throw(" + e + ")"); return { value: "thrown-" + e, done: false }; };
  if (withReturn) it.return = (v) => { log.push(label + ".return(" + v + ")"); return Promise.resolve({ value: "ret-" + v, done: true }); };
  return it;
}
async function* delegate(src) {
  try {
    const r = yield* src;
    yield "final " + r;
  } catch (e) {
    yield "outer caught " + errName(e);
  }
}
(async () => {
  const out = [];
  const a = delegate(customAsync("A", true, true));
  out.push(show(await a.next()), show(await a.throw("t")), show(await a.return("r")), show(await a.next()));
  const b = delegate(customAsync("B", false, true));
  out.push(show(await b.next()), show(await b.throw("t")), show(await b.next()));
  const c = delegate(customAsync("C", false, false));
  out.push(show(await c.next()), show(await c.return(Promise.resolve("noreturn"))), show(await c.next()));
  const d = delegate(customAsync("D", false, false));
  out.push(show(await d.next()), show(await d.next()), show(await d.next()), show(await d.next()));
  print("custom inner:", out.join(" "));
})();

// non-object inner results → TypeError
async function* badInner() {
  try {
    yield* { [Symbol.asyncIterator]() { return { next() { return 5; } }; } };
  } catch (e) {
    yield "bad result " + errName(e);
  }
}
collect(badInner()).then((s) => print("non-object inner:", s));

// ---- exact interleaving with other promise chains
(async () => {
  const order = [];
  async function* ticks() {
    order.push("g:start");
    yield "a";
    order.push("g:after a");
    await null;
    order.push("g:after await");
    yield Promise.resolve("b");
    order.push("g:end");
  }
  const it = ticks();
  it.next().then((r) => order.push("n1:" + r.value));
  it.next().then((r) => order.push("n2:" + r.value));
  it.next().then((r) => order.push("n3:" + r.done));
  it.return("x").then((r) => order.push("ret:" + r.value));
  let p = Promise.resolve();
  for (let i = 1; i <= 10; i++) p = p.then(() => order.push("t" + i));
  await p;
  print("ticks:", order.join(" "));
})();

Promise.resolve().then(() => new Promise((res) => {
  let n = 0;
  const spin = () => (++n < 40 ? Promise.resolve().then(spin) : res());
  spin();
})).then(() => print("log:", log.join(" | ")));
