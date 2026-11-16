// M10.0 pure-JS benchmark: closure creation and captured cell access
// Iterations: 500,000
function makeCounter(start) {
  let n = start;
  return function(d) {
    n = n + d;
    return n;
  };
}
let total = 0;
for (let i = 0; i < 500000; i++) {
  let c = makeCounter(i % 100);
  total = (total + c(1) + c(2)) % 1000000007;
}
print('RESULT', total);
