// Macro benchmark: JSON.stringify / JSON.parse round-trips with a reviver.
// Exercises serialization, parsing, object/array allocation, and reviver callbacks.
const _print = typeof print === "function" ? print : console.log;

function makeRng(seed) {
  let s = seed | 0;
  return function next() {
    s = (s + 0x6d2b79f5) | 0;
    let t = Math.imul(s ^ (s >>> 15), 1 | s);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0);
  };
}

const rng = makeRng(0x9e3779b9);
const tagsPool = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta"];

function buildBatch(batchIdx) {
  const rows = [];
  for (let i = 0; i < 40; i++) {
    const r = rng();
    const tags = [];
    const nTags = 1 + (r % 4);
    for (let t = 0; t < nTags; t++) {
      tags.push(tagsPool[(r + t * 3) % tagsPool.length]);
    }
    rows.push({
      id: batchIdx * 40 + i,
      active: (r & 1) === 0,
      score: (r % 10000),
      label: "node-" + (r % 256),
      tags: tags,
      meta: {
        created: "2026-01-" + (10 + (r % 18)),
        weight: (r >>> 8) % 500,
        nested: (r & 4) === 0 ? null : { flag: (r & 8) !== 0, code: r % 97 },
      },
    });
  }
  return { version: 2, batch: batchIdx, rows: rows };
}

function reviver(key, value) {
  if (key === "score" && typeof value === "number") {
    return value + 1;
  }
  if (key === "label" && typeof value === "string") {
    return value.toUpperCase();
  }
  if (key === "nested" && value === null) {
    return { flag: false, code: 0 };
  }
  return value;
}

let checksum = 0x811c9dc5;
const ROUNDS = 900;

for (let i = 0; i < ROUNDS; i++) {
  const payload = buildBatch(i);
  const text = JSON.stringify(payload);
  const parsed = JSON.parse(text, reviver);

  checksum = Math.imul(checksum ^ text.length, 0x01000193) >>> 0;
  const rows = parsed.rows;
  for (let j = 0; j < rows.length; j++) {
    const row = rows[j];
    const h = (row.id + row.score + row.tags.length + row.meta.weight + row.meta.nested.code) | 0;
    checksum = Math.imul(checksum ^ h, 0x01000193) >>> 0;
  }
}

_print("RESULT " + checksum);
