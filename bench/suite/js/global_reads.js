// Pure-JS benchmark: repeated top-level global reads in loop
// Iterations: 1,000,000
const G_A = 3;
const G_B = 7;
const G_C = 11;
let acc = 0;
for (let i = 0; i < 1000000; i++) {
  acc = (acc + G_A * (i % G_B) + G_C) % 1000000007;
}
print('RESULT', acc);
