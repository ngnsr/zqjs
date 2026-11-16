// M10.0 pure-JS benchmark: array push, pop, indexed read/write
// Iterations: 100,000 outer * 20 elements
let total = 0;
for (let k = 0; k < 100000; k++) {
  let arr = [];
  for (let i = 0; i < 20; i++) arr.push(i + (k % 7));
  for (let i = 0; i < 20; i++) arr[i] = arr[i] * 2;
  for (let i = 0; i < 20; i++) total = (total + arr[i]) % 1000000007;
}
print('RESULT', total);
