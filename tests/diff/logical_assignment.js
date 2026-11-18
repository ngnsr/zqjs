function log(tag, val) {
  print('eval:' + tag);
  return val;
}

// Short-circuiting and result values on locals
let a = 0;
print('a1:', a &&= log('a1', 99), a);
a = 1;
print('a2:', a &&= log('a2', 42), a);

let b = 5;
print('b1:', b ||= log('b1', 99), b);
b = '';
print('b2:', b ||= log('b2', 'ok'), b);

let c = 0;
print('c1:', c ??= log('c1', 99), c);
c = false;
print('c2:', c ??= log('c2', 99), c);
c = '';
print('c3:', c ??= log('c3', 99), c);
c = null;
print('c4:', c ??= log('c4', 'from-null'), c);
c = undefined;
print('c5:', c ??= log('c5', 'from-undef'), c);

// Chaining (right-associative)
let x = 1;
let y = 0;
let z = null;
print('chain:', x &&= y ||= z ??= 7, x, y, z);

// Member targets evaluated once (property and computed element)
let calls = 0;
function getObj(o) {
  calls++;
  print('obj:' + calls);
  return o;
}
function getKey(k) {
  calls++;
  print('key:' + calls);
  return k;
}

const rec = { t: 10, f: 0, n: null, u: undefined };
print('m1:', getObj(rec).f &&= log('m1', 1), rec.f);
print('m2:', getObj(rec).t &&= log('m2', 2), rec.t);
print('m3:', getObj(rec).t ||= log('m3', 3), rec.t);
print('m4:', getObj(rec)[getKey('f')] ||= log('m4', 4), rec.f);
print('m5:', getObj(rec)[getKey('f')] ??= log('m5', 5), rec.f);
print('m6:', getObj(rec)[getKey('n')] ??= log('m6', 6), rec.n);
print('m7:', getObj(rec).u ??= log('m7', 7), rec.u);

// Array elements
const arr = [0, 1, null];
print('arr0:', arr[getKey(0)] ??= log('arr0', 99), arr[0]);
print('arr1:', arr[getKey(1)] ||= log('arr1', 99), arr[1]);
print('arr2:', arr[getKey(2)] ??= log('arr2', 33), arr[2]);

// const binding: short-circuit does NOT throw TypeError; write DOES throw TypeError
const k0 = 0;
k0 &&= log('never-k0', 1);
const k1 = 1;
k1 ||= log('never-k1', 2);
const k2 = false;
k2 ??= log('never-k2', 3);
print('const-ok:', k0, k1, k2);

try {
  const w1 = 1;
  w1 &&= log('w1-rhs', 2);
} catch (e) {
  print('w1:', e.name);
}
try {
  const w2 = 0;
  w2 ||= log('w2-rhs', 2);
} catch (e) {
  print('w2:', e.name);
}
try {
  const w3 = null;
  w3 ??= log('w3-rhs', 2);
} catch (e) {
  print('w3:', e.name);
}

// TDZ ReferenceError before short-circuit check
try {
  tdz &&= 1;
  let tdz = 0;
} catch (e) {
  print('tdz:', e.name);
}

// Null/undefined base throws TypeError before RHS
try {
  let bad = null;
  bad.p &&= log('never-bad', 1);
} catch (e) {
  print('bad:', e.name);
}

// Captured closure binding
function counter(init) {
  let v = init;
  return () => v ??= log('init-v', 100);
}
const cA = counter(null);
print('cap1:', cA(), cA());
const cB = counter(0);
print('cap2:', cB());
