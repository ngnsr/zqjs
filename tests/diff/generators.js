// Synchronous generators (M37, D67)
function show(r) {
  return "{" + String(r.value) + "," + r.done + "}";
}
function drain(it) {
  const out = [];
  for (const v of it) out.push(v);
  return out.join(",");
}

// ---- declarations, expressions, methods
function* decl() { yield 1; yield 2; return 3; }
const g1 = decl();
print("decl:", show(g1.next()), show(g1.next()), show(g1.next()), show(g1.next()));

const anon = function* () { yield "a"; };
const named = function* inner(n) { if (n > 0) yield* inner(n - 1); yield n; };
print("expr:", drain(anon()), drain(named(3)), named.name, anon.name);

const obj = {
  *m() { yield "m"; },
  *["comp" + "uted"]() { yield "c"; },
};
print("obj methods:", drain(obj.m()), drain(obj.computed()));

const key = "dyn";
class C {
  constructor() { this.base = 10; }
  *items() { yield this.base; yield this.base + 1; }
  static *range(a, b) { for (let i = a; i < b; i++) yield i; }
  *[key]() { yield "k"; }
  #secret = 5;
  *#priv() { yield this.#secret; }
  callPriv() { return drain(this.#priv()); }
}
const c = new C();
print("class methods:", drain(c.items()), drain(C.range(2, 5)), drain(c.dyn()), c.callPriv());

// ---- two-way next(v); the first argument is ignored
function* echo() {
  const a = yield "first";
  const b = yield "got " + a;
  return "end " + b;
}
const e = echo();
print("next(v):", show(e.next("ignored")), show(e.next("x")), show(e.next("y")), show(e.next("z")));

function* inExpr() {
  const arr = [1, yield "a", 3, yield "b"];
  return arr.join("|");
}
const ie = inExpr();
print("yield in expr:", show(ie.next()), show(ie.next(2)), show(ie.next(4)));

// ---- return(v)
const log = [];
function* withFinally() {
  try {
    yield 1;
    yield 2;
  } finally {
    log.push("cleanup");
  }
}
const wf = withFinally();
wf.next();
print("return through finally:", show(wf.return(42)), log.join(","), show(wf.next()));

function* yieldInFinally() {
  try {
    yield 1;
  } finally {
    yield "in finally";
    log.push("after finally yield");
  }
}
const yf = yieldInFinally();
yf.next();
print("yield in finally:", show(yf.return("r")), show(yf.next()), show(yf.next()));

function* finallyOverridesReturn() {
  try {
    yield 1;
  } finally {
    return "override";
  }
}
const fo = finallyOverridesReturn();
fo.next();
print("finally overrides return:", show(fo.return("lost")));

function* finallyThrows() {
  try {
    yield 1;
  } finally {
    throw new Error("from finally");
  }
}
const ft = finallyThrows();
ft.next();
try {
  ft.return(1);
} catch (err) {
  print("finally throws:", err.message, show(ft.next()));
}

function* returnInsideExpr() {
  try {
    const v = [0, (yield 1) + 1];
    return v;
  } finally {
    log.push("expr finally");
  }
}
const ri = returnInsideExpr();
ri.next();
print("return mid-expression:", show(ri.return("mid")), log[log.length - 1]);

// ---- throw(e)
function* catcher() {
  while (true) {
    try {
      yield "waiting";
    } catch (err) {
      yield "caught " + err;
    }
  }
}
const ct = catcher();
ct.next();
print("throw caught:", show(ct.throw("boom")), show(ct.next()), show(ct.throw("again")));

function* throwThroughFinally() {
  try {
    yield 1;
  } finally {
    log.push("throw finally");
  }
}
const tt = throwThroughFinally();
tt.next();
try {
  tt.throw(new Error("passes"));
} catch (err) {
  print("throw through finally:", err.message, log[log.length - 1], show(tt.next()));
}

// ---- suspendedStart and completed
function* neverStarted() {
  try {
    yield 1;
  } finally {
    log.push("never runs");
  }
}
const ns = neverStarted();
print("return at start:", show(ns.return("early")), show(ns.next()), log.includes("never runs"));
const ns2 = neverStarted();
try {
  ns2.throw("start throw");
} catch (err) {
  print("throw at start:", err, show(ns2.next()));
}
const done = decl();
drain(done);
print("completed:", show(done.next()), show(done.return(7)));
try {
  done.throw("after");
} catch (err) {
  print("throw on completed:", err);
}

// ---- re-entrancy
let self;
function* reentrant() {
  try {
    self.next();
  } catch (err) {
    yield (err instanceof TypeError) + " " + err.message;
  }
}
self = reentrant();
print("re-entrancy:", show(self.next()));

// ---- not constructable, prototypes
try {
  new decl();
} catch (err) {
  print("new genFn:", err instanceof TypeError);
}
const genProto = Object.getPrototypeOf(decl());
const GeneratorPrototype = Object.getPrototypeOf(decl.prototype);
const IteratorPrototype = Object.getPrototypeOf(GeneratorPrototype);
print("proto chain:", genProto === decl.prototype,
  GeneratorPrototype === Object.getPrototypeOf(anon.prototype),
  Object.getPrototypeOf(IteratorPrototype) === Object.prototype,
  typeof GeneratorPrototype.next, typeof GeneratorPrototype.return, typeof GeneratorPrototype.throw,
  Object.getOwnPropertyDescriptor(decl.prototype, "constructor") !== undefined, Object.keys(decl.prototype).length);
const it = decl();
print("Symbol.iterator:", it[Symbol.iterator]() === it, Object.prototype.toString.call(it));
decl.prototype = null;
print("null prototype:", Object.getPrototypeOf(decl()) === GeneratorPrototype);
try {
  GeneratorPrototype.next.call({});
} catch (err) {
  print("bad receiver:", err instanceof TypeError);
}

// ---- parameter defaults run on the call
const order = [];
function* params(a = order.push("default")) {
  order.push("body");
  yield a;
}
const pg = params();
order.push("created");
pg.next();
print("defaults on call:", order.join(","));
function* throwingDefault(a = (() => { throw new Error("bad default"); })()) {
  yield a;
}
try {
  throwingDefault();
} catch (err) {
  print("default throws at call:", err.message);
}

// ---- iteration protocol
function* tracked(tag) {
  try {
    yield 1;
    yield 2;
    yield 3;
  } finally {
    log.push("closed " + tag);
  }
}
for (const v of tracked("break")) if (v === 2) break;
function useReturn() {
  for (const v of tracked("return")) return v;
}
useReturn();
try {
  for (const v of tracked("throw")) throw new Error("x" + v);
} catch (err) {}
print("for-of closes:", log.filter(s => s.startsWith("closed")).join(","));

print("spread:", [...decl()].join(","), Math.max(...C.range(0, 4)));
const [first] = tracked("destructure");
const [p, q, ...rest] = C.range(0, 6);
print("destructuring:", first, log[log.length - 1], p, q, rest.join(","));
print("Array.from:", Array.from(C.range(1, 4)).join(","), Array.from(decl(), x => x * 10).join(","));
const set = new Set(echo());
print("Set:", [...set].join("|"));
function* pairs() { yield ["a", 1]; yield ["b", 2]; }
const map = new Map(pairs());
print("Map:", map.get("a"), map.get("b"), map.size);

// ---- yield*
function* overArray() { const r = yield* [1, 2]; yield r; }
print("yield* array:", drain(overArray()));
function* overString() { yield* "hé!"; }
print("yield* string:", drain(overString()));

function customIter(withThrow, withReturn) {
  const calls = [];
  let i = 0;
  const iter = {
    calls,
    [Symbol.iterator]() { return this; },
    next(v) { calls.push("next:" + v); i++; return i > 2 ? { value: "inner-done", done: true } : { value: i, done: false }; },
  };
  if (withThrow) iter.throw = function (v) { calls.push("throw:" + v); return { value: "recovered", done: false }; };
  if (withReturn) iter.return = function (v) { calls.push("return:" + v); return { value: "ret:" + v, done: true }; };
  return iter;
}
function* delegate(inner) {
  const r = yield* inner;
  yield "result " + r;
}
const ci = customIter(false, false);
const d1 = delegate(ci);
print("yield* custom:", show(d1.next("a")), show(d1.next("b")), show(d1.next("c")), ci.calls.join(","));

const ct2 = customIter(true, true);
const d2 = delegate(ct2);
d2.next();
print("forward throw:", show(d2.throw("t")), show(d2.return("bye")), ct2.calls.join(","));

const noThrow = customIter(false, true);
const d3 = delegate(noThrow);
d3.next();
try {
  d3.throw("x");
} catch (err) {
  print("missing throw:", err instanceof TypeError, noThrow.calls.join(","), show(d3.next()));
}

const noReturn = customIter(false, false);
const d4 = delegate(noReturn);
d4.next();
print("missing return:", show(d4.return("outer")), show(d4.next()));

function* innerGen() {
  try {
    const x = yield "i1";
    yield "i2:" + x;
  } finally {
    log.push("inner finally");
  }
  return "inner-ret";
}
function* outerGen() {
  try {
    const r = yield* innerGen();
    yield "outer got " + r;
  } finally {
    log.push("outer finally");
  }
}
const og = outerGen();
print("nested:", show(og.next()), show(og.next("v")), show(og.next()), show(og.next()));
const og2 = outerGen();
og2.next();
print("nested return:", show(og2.return("stop")), log.slice(-2).join(","));
const og3 = outerGen();
og3.next();
try {
  og3.throw(new Error("deep"));
} catch (err) {
  print("nested throw:", err.message, log.slice(-2).join(","));
}

// yield* hands the inner result object through as is
const marker = { value: "raw", done: false, extra: "kept" };
const rawIter = { [Symbol.iterator]() { return this; }, next() { return marker; } };
function* rawDelegate() { yield* rawIter; }
const rd = rawDelegate().next();
print("identity:", rd === marker, rd.extra);

// generators are recursive and lazy
function* naturals() { let n = 0; while (true) yield n++; }
function* take(n, it) { for (const v of it) { if (n-- <= 0) return; yield v; } }
print("lazy:", [...take(5, naturals())].join(","));
function* tree(depth) { if (depth === 0) { yield "leaf"; return; } yield* tree(depth - 1); yield* tree(depth - 1); }
print("recursive yield*:", [...tree(3)].length);
