// Generates the node-derived expected outputs ("goldens") that `zig build test` checks:
//   tests/ops/*.jsonl   conversion and operator tables for src/runtime/ops.zig
//   tests/diff/*.out    the output of each tests/diff/*.js program under node
// Usage:
//   node golden.js          regenerate everything
//   node golden.js --check  fail if any golden is out of date (run by `zig build check-goldens`)
// Portability: node's `**` (and Math.log) can differ in the last bit between platforms, so
// results of `**` are checked within 1 ulp, and the pow.jsonl *inputs* are frozen data (see there).
// Everything else must match byte for byte.
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.join(__dirname, '..');
const check = process.argv.includes('--check');
let stale = 0;

function emit(file, content, sameLine = (a, b) => a === b) {
  const full = path.join(root, file);
  if (check) {
    const old = fs.existsSync(full) ? fs.readFileSync(full, 'utf8').split('\n') : null;
    const now = content.split('\n');
    const sameLength = old !== null && old.length === now.length;
    const bad = sameLength ? old.findIndex((l, i) => !sameLine(l, now[i])) : -1;
    if (!sameLength || bad !== -1) {
      stale++; console.log(`out of date: ${file}`);
      if (bad >= 0) console.log(`  line ${bad + 1}\n  committed: ${old[bad]}\n  node now:  ${now[bad]}`);
    }
  } else {
    fs.writeFileSync(full, content);
  }
}

// Exact float64 encoding: 16 hex digits of the IEEE-754 bits.
function bits(x) { const b = Buffer.alloc(8); b.writeDoubleBE(x); return b.toString('hex'); }
// Bits of a computed result. A NaN result's sign bit is platform noise (x86 makes inf + -inf = fff8…, arm 7ff8…).
function resultBits(x) { return Number.isNaN(x) ? '7ff8000000000000' : bits(x); }
function fromBits(h) { return Buffer.from(h, 'hex').readDoubleBE(); }

// True if two bit strings are the same double or adjacent doubles (any two NaNs count as equal).
function within1Ulp(a, b) {
  if (a === b) return true;
  if (Number.isNaN(fromBits(a)) || Number.isNaN(fromBits(b))) return Number.isNaN(fromBits(a)) && Number.isNaN(fromBits(b));
  const key = (h) => { const v = BigInt('0x' + h); return v >> 63n ? -(v & ((1n << 63n) - 1n)) : v; }; // monotonic in value
  const d = key(a) - key(b);
  return d >= -1n && d <= 1n;
}

// Deterministic pseudo-random doubles (xorshift64), so the tables don't change between runs.
function* randomDoubles(n) {
  let s = 0x9E3779B97F4A7C15n;
  const mask = (1n << 64n) - 1n;
  const b = Buffer.alloc(8);
  for (let i = 0; i < n; i++) {
    s ^= (s << 13n) & mask; s ^= s >> 7n; s ^= (s << 17n) & mask;
    b.writeBigUInt64BE(s);
    yield b.readDoubleBE();
  }
}

// ---- tests/ops/number_to_string.jsonl: [bits, String(x)]
{
  const special = [0, -0, NaN, Infinity, -Infinity, 1, -1, 0.1, 0.2, 0.1 + 0.2, 1 / 3, 2 / 3, 100, 1e21, 1e20,
    999999999999999900000, 1e-6, 1e-7, 1.5e-7, 0.000001234, 123456789012345680000, 5e-324, 2.2250738585072014e-308,
    1.7976931348623157e308, 2 ** 53, 2 ** 53 + 2, 123.456, -1.5, 1e300, 1.5e300, 4.35, 0.5, 1e-5, 12345e-10];
  // Parsed, not `10 ** e`: node's `**` changed in the last bit between versions (22 vs 26).
  for (let e = -30; e <= 30; e++) special.push(Number(`1e${e}`), Number(`1.25e${e}`), -Number(`7e${e}`));
  const lines = [...special, ...randomDoubles(3000)].map((x) => JSON.stringify([bits(x), String(x)]));
  emit('ops/number_to_string.jsonl', lines.join('\n') + '\n');
}

// ---- tests/ops/string_to_number.jsonl: [input, bits]
{
  const inputs = ['', ' ', '0', '-0', '+0', '1', '-1', '  12  ', '\n\t 1e3  ', '  7 ﻿', '　 8',
    '0x10', '0X1f', '-0x10', '+0x10', '0x', '0xg', '0b101', '0B11', '0b2', '0o17', '0O7', '0o8', '1_000', '.5', '5.',
    '+.5', '-.5e1', '.', '+', '-', 'e5', '1e', '1e+', '1e-7', '1E21', 'Infinity', '+Infinity', '-Infinity', 'infinity',
    'INFINITY', 'NaN', '12px', '00012', '0012.5', '1.2.3', '1e400', '-1e400', '1e-400', '9007199254740993',
    '0x1fffffffffffff1', '0x' + 'f'.repeat(300), '0b' + '1'.repeat(60), '0o' + '7'.repeat(30), '1'.repeat(400),
    '0.' + '0'.repeat(350) + '1', 'é', '1é', ' ', '1 2', '0.1e-1', '1e+0', '  -  1'];
  emit('ops/string_to_number.jsonl', inputs.map((s) => JSON.stringify([s, bits(+s)])).join('\n') + '\n');
}

// ---- tests/ops/arithmetic.jsonl: [op, a bits, b bits, result bits]
{
  const vals = [0, -0, 1, -1, 0.5, -0.5, 2, -2, 3, -8, 1 / 3, NaN, Infinity, -Infinity, 1e308, 5e-324, -5e-324, 2 ** 53];
  const ops = { '+': (a, b) => a + b, '-': (a, b) => a - b, '*': (a, b) => a * b, '/': (a, b) => a / b,
    '%': (a, b) => a % b, '**': (a, b) => a ** b };
  const lines = [];
  for (const [op, f] of Object.entries(ops)) for (const a of vals) for (const b of vals)
    lines.push(JSON.stringify([op, bits(a), bits(b), resultBits(f(a, b))]));
  emit('ops/arithmetic.jsonl', lines.join('\n') + '\n', (o, n) => {
    if (o === n || !o.startsWith('["**"')) return o === n;
    const [x, y] = [JSON.parse(o), JSON.parse(n)];
    return x[1] === y[1] && x[2] === y[2] && within1Ulp(x[3], y[3]);
  });
}

// ---- tests/ops/pow.jsonl: [base bits, exponent bits, result bits] for x ** y.
// Special-value grid plus ~8,000 pseudo-random cases aimed at the hard regions.
// The inputs are frozen: some are computed with `**` and Math.log, which are not bit-portable, and
// tools/pow_reference.py, the pow-bits hash and the accuracy counts in DESIGN_DECISIONS D25 all
// depend on them. So they are read back from the committed file; delete it to regenerate them.
{
  const powFile = path.join(root, 'ops/pow.jsonl');
  const frozen = fs.existsSync(powFile);
  function* uniform(n, seed) { // doubles in [0, 1)
    let s = BigInt(seed) | 1n;
    const mask = (1n << 64n) - 1n;
    for (let i = 0; i < n; i++) {
      s ^= (s << 13n) & mask; s ^= s >> 7n; s ^= (s << 17n) & mask;
      yield Number(s >> 11n) / 2 ** 53;
    }
  }
  const pairs = frozen ? fs.readFileSync(powFile, 'utf8').trim().split('\n').map((l) => JSON.parse(l).slice(0, 2).map(fromBits)) : [];
  if (!frozen) {
    const specials = [0, -0, 1, -1, 2, -2, 0.5, -0.5, 3, -3, 1 / 3, 10, -8, 1e308, -1e308, 5e-324, -5e-324,
      2.2250738585072014e-308, 1.0000000000000002, 0.9999999999999999, NaN, Infinity, -Infinity, 2 ** 53, -(2 ** 53) - 2, 1023.5, -1074, 1024];
    for (const a of specials) for (const b of specials) pairs.push([a, b]);
    const u = (n, seed) => [...uniform(n, seed)];
    const A = u(3000, 1), B = u(3000, 2);
    for (let i = 0; i < 3000; i++) pairs.push([A[i] * 10, B[i] * 60 - 30]);                    // everyday ranges
    const C = u(1000, 3), D = u(1000, 4);
    for (let i = 0; i < 1000; i++) pairs.push([2 ** (C[i] * 2000 - 1000), D[i] * 6 - 3]);       // any magnitude
    const E = u(1000, 5), F = u(1000, 6);
    for (let i = 0; i < 1000; i++) pairs.push([-(E[i] * 20), Math.round(F[i] * 120 - 60)]);    // negative base, integer exponent
    const G = u(1000, 7), H = u(1000, 8);
    for (let i = 0; i < 1000; i++) pairs.push([1 + (G[i] - 0.5) * 2 ** -(H[i] * 50), (H[i] - 0.5) * 2e12]); // near 1, huge exponent
    const I = u(1000, 9), J = u(1000, 10);
    for (let i = 0; i < 1000; i++) {                                                           // results near overflow / underflow
      const base = 1.5 + I[i] * 100, edge = (J[i] < 0.5 ? 1024 : -1074) * Math.LN2 / Math.log(base);
      pairs.push([base, edge * (1 + (J[i] - 0.5) * 1e-3)]);
  }
  const K = u(500, 11), M = u(500, 12);
  for (let i = 0; i < 500; i++) pairs.push([K[i] * 2 ** -1022, M[i] * 2 - 1]);               // subnormal bases
  }
  emit('ops/pow.jsonl', pairs.map(([a, b]) => JSON.stringify([bits(a), bits(b), bits(a ** b)])).join('\n') + '\n', (o, n) => {
    if (o === n) return true;
    const [x, y] = [JSON.parse(o), JSON.parse(n)];
    return x[0] === y[0] && x[1] === y[1] && within1Ulp(x[2], y[2]);
  });
}

// ---- tests/diff/*.out: the program's output under node with ZQJS's `print`.
function runInNode(source) {
  let out = '';
  const print = (...args) => { out += args.map(String).join(' ') + '\n'; };
  try {
    vm.runInNewContext(source, { print }, { timeout: 5000, microtaskMode: 'afterEvaluate' }); // drain promise jobs like ZQJS's end-of-run checkpoint
  } catch (e) {
    out += `Uncaught ${e.name}\n`; // names only: messages are never compared
  }
  // Lone surrogates become U+FFFD when node writes UTF-8; do the same here.
  return Buffer.from(out, 'utf8').toString('utf8');
}
const diffDir = path.join(root, 'diff');
for (const f of fs.readdirSync(diffDir).filter((f) => f.endsWith('.js')).sort()) {
  emit(`diff/${f.replace(/\.js$/, '.out')}`, runInNode(fs.readFileSync(path.join(diffDir, f), 'utf8')));
}

if (check) {
  console.log(stale ? `${stale} golden file(s) out of date; run: node tests/harness/golden.js` : 'goldens up to date');
  process.exit(stale ? 1 : 0);
}
