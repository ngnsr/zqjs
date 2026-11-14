// Per-iteration for-let bindings captured by a closure created in every iteration.
let sum = 0;
for (let i = 0; i < 100000; i++) { const f = function () { return i; }; sum = sum + f(); }
print(sum);
