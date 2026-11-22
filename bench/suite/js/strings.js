// Pure-JS benchmark: string concatenation and length
// Iterations: 100,000
let total = 0;
for (let i = 0; i < 100000; i++) {
  let s = 'item-' + i + ':' + (i % 100);
  total = total + s.length;
}
print('RESULT', total);
