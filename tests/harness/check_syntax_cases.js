// Checks the ZQJS compatibility contract (LANGUAGE.md §1) against node:
//   "ok"     cases must not raise a SyntaxError in node,
//   "syntax" cases must raise a SyntaxError in node,
//   "unsupported:*" cases make no claim (only counted).
// Scripts are compiled *and run* in a fresh context, because some SyntaxErrors are
// only raised when a script is instantiated (e.g. top-level `let undefined`).
// Runtime errors (ReferenceError, TypeError, timeouts) don't matter here: they
// belong to the runtime, not to the syntax contract.
// Usage: node check_syntax_cases.js cases.jsonl
'use strict';
const fs = require('fs');
const vm = require('vm');

function syntaxErrorOf(source) {
  try {
    vm.runInNewContext(source, {}, { timeout: 200 });
  } catch (e) {
    if (e instanceof SyntaxError || e?.name === 'SyntaxError') return e;
  }
  return null;
}

const lines = fs.readFileSync(process.argv[2], 'utf8').split('\n');
let failures = 0;
const counts = { ok: 0, syntax: 0, unsupported: 0, unsupportedValidInNode: 0 };

lines.forEach((line, i) => {
  if (line === '') return;
  const [outcome, source] = JSON.parse(line);
  const err = syntaxErrorOf(source);
  const where = `cases.jsonl:${i + 1}: ${JSON.stringify(source)}`;
  if (outcome === 'ok') {
    counts.ok++;
    if (err) { failures++; console.log(`${where}: ZQJS accepts it, node: ${err}`); }
  } else if (outcome === 'syntax') {
    counts.syntax++;
    if (!err) { failures++; console.log(`${where}: ZQJS says SyntaxError, node accepts it`); }
  } else {
    counts.unsupported++;
    if (!err) counts.unsupportedValidInNode++;
  }
});

console.log(`ok: ${counts.ok}, syntax: ${counts.syntax}, unsupported: ${counts.unsupported} ` +
  `(${counts.unsupportedValidInNode} valid in node), contract violations: ${failures}`);
process.exit(failures ? 1 : 0);
