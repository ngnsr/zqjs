// Closure calls over shared mutable captured state, and capture through two levels.
function counter() { let n = 0; return function () { n = n + 1; return n; }; }
function adder(x) { return function (y) { return function (z) { return x + y + z; }; }; }
const c = counter();
let total = 0;
for (let i = 0; i < 100000; i++) { total = total + c() + adder(i)(1)(2); }
print(total);
