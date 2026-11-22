// Pure-JS benchmark: small non-recursive function calls
// Iterations: 1,000,000 outer iterations * 3 calls = 3,000,000 calls
function step1(x, y) { return x + y * 2; }
function step2(a, b) { return step1(a, b) - 3; }
let acc = 0;
for (let i = 0; i < 1000000; i++) {
  acc = (acc + step2(i % 97, i % 31)) % 1000000007;
}
print('RESULT', acc);
