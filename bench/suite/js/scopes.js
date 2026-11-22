// Pure-JS benchmark: nested lexical scopes without closure capture
// Iterations: 1,000,000
let sum = 0;
for (let i = 0; i < 1000000; i++) {
  let a = i % 13;
  {
    let b = a + 7;
    {
      let c = b * 3;
      sum = (sum + c) % 1000000007;
    }
  }
}
print('RESULT', sum);
