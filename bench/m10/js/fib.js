// M10.0 pure-JS benchmark: recursive function calls
// Workload: fib(29) (1,664,079 calls)
function fib(n) {
  if (n < 2) return n;
  return fib(n - 1) + fib(n - 2);
}
print('RESULT', fib(29));
