// Pure-JS benchmark: branch-dense comparisons & control flow
// Iterations: 2,000,000 (fixed; no heap allocations)
let a = 1;
let b = 2;
let c = 3;
for (let i = 0; i < 2000000; i++) {
  let m = i % 5;
  if (m === 0) {
    a = (a + b) % 997;
  } else if (m === 1) {
    b = (b + c) % 991;
  } else if (m === 2) {
    c = (c + a) % 983;
  } else if (m === 3) {
    if (a > b) a = a - 1; else b = b + 1;
  } else {
    c = c + 2;
  }
}
print('RESULT', a * 1000000 + b * 1000 + c);
