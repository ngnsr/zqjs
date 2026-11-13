// Checks the ZQJS compatibility contract (LANGUAGE.md §1) against node:
//   "ok"     cases must parse in node,
//   "syntax" cases must be a node SyntaxError,
//   "unsupported:*" cases make no claim (only counted).
// Usage: node check_syntax_cases.js cases.jsonl
'use strict';
const fs = require('fs');
const vm = require('vm');

const lines = fs.readFileSync(process.argv[2], 'utf8').split('\n');
let failures = 0;
const counts = { ok: 0, syntax: 0, unsupported: 0, unsupportedValidInNode: 0 };

lines.forEach((line, i) => {
  if (line === '') return;
  const [outcome, source] = JSON.parse(line);
  let nodeError = null;
  try {
    new vm.Script(source); // parses as a classic (sloppy) script, without running it
  } catch (e) {
    nodeError = e;
  }
  const where = `cases.jsonl:${i + 1}: ${JSON.stringify(source)}`;
  if (outcome === 'ok') {
    counts.ok++;
    if (nodeError) { failures++; console.log(`${where}: ZQJS accepts it, node rejects: ${nodeError}`); }
  } else if (outcome === 'syntax') {
    counts.syntax++;
    if (!(nodeError instanceof SyntaxError)) { failures++; console.log(`${where}: ZQJS says SyntaxError, node accepts it`); }
  } else {
    counts.unsupported++;
    if (!nodeError) counts.unsupportedValidInNode++;
  }
});

console.log(`ok: ${counts.ok}, syntax: ${counts.syntax}, unsupported: ${counts.unsupported} ` +
  `(${counts.unsupportedValidInNode} valid in node), contract violations: ${failures}`);
process.exit(failures ? 1 : 0);
