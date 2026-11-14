// Recursion, mutual recursion through hoisting, calling before the declaration.
print(fact(10), fib(20), isEven(10), isEven(7));
function fact(n) { if (n <= 1) return 1; return n * fact(n - 1); }
function fib(n) { if (n < 2) return n; return fib(n - 1) + fib(n - 2); }
function isEven(n) { if (n === 0) return true; return isOdd(n - 1); }
function isOdd(n) { if (n === 0) return false; return isEven(n - 1); }
// A recursive named function expression; its name is visible only inside it.
const down = function count(n) { if (n === 0) return 'done'; return count(n - 1); };
print(down(300));
function depth(n) { if (n === 0) return 0; return 1 + depth(n - 1); }
print(depth(500));
