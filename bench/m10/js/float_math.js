// M10.0 pure-JS benchmark: floating-point arithmetic (exact dyadic steps)
// Iterations: 2,000,000 (fixed; no heap allocations)
let x = 1.5;
let y = -0.75;
let acc = 0.0;
for (let i = 0; i < 2000000; i++) {
  let dx = (i % 4) * 0.25 - 0.375;
  let dy = (i % 8) * 0.125 - 0.5;
  x = x * 0.5 + dx;
  y = y * 0.5 + dy;
  acc = acc + x * x + y * y;
}
print('RESULT', acc);
