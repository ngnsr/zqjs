// Pure-JS benchmark: integer-style arithmetic & locals
// Iterations: 2,000,000 (fixed; no heap allocations)
let s = 0;
for (let i = 0; i < 2000000; i++) {
  if (i % 3 === 0) continue;
  s = (s + i * 3 - (i % 7)) % 1000000007;
}
print('RESULT', s);
