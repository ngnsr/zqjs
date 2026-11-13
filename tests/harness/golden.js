// Generates the node-derived expected outputs ("goldens") that `zig build test` checks:
//   tests/ops/*.jsonl   conversion and operator tables for src/runtime/ops.zig
//   tests/diff/*.out    the output of each tests/diff/*.js program under node
// Usage:
//   node golden.js          regenerate everything
//   node golden.js --check  fail if any golden is out of date (run by `zig build check-node`)
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.join(__dirname, '..');
const check = process.argv.includes('--check');
let stale = 0;

function emit(file, content) {
  const full = path.join(root, file);
  if (check) {
    const old = fs.existsSync(full) ? fs.readFileSync(full, 'utf8') : null;
    if (old !== content) { stale++; console.log(`out of date: ${file}`); }
  } else {
    fs.writeFileSync(full, content);
  }
}

// Exact float64 encoding: 16 hex digits of the IEEE-754 bits.
function bits(x) { const b = Buffer.alloc(8); b.writeDoubleBE(x); return b.toString('hex'); }

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
  for (let e = -30; e <= 30; e++) special.push(10 ** e, 1.25 * 10 ** e, -(7 * 10 ** e));
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
    lines.push(JSON.stringify([op, bits(a), bits(b), bits(f(a, b))]));
  emit('ops/arithmetic.jsonl', lines.join('\n') + '\n');
}

// ---- tests/diff/*.out: the program's output under node with ZQJS's `print`.
function runInNode(source) {
  let out = '';
  const print = (...args) => { out += args.map(String).join(' ') + '\n'; };
  try {
    vm.runInNewContext(source, { print }, { timeout: 5000 });
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
