// Arrays: push/pop, indexed reads and writes, length, and join on nested arrays.
let a = [];
for (let i = 0; i < 100000; i++) a.push(i * 2);
let sum = 0;
for (let i = 0; i < a.length; i++) { a[i] = a[i] + 1; sum = sum + a[i]; }
while (a.length > 50000) a.pop();
let rows = [];
for (let r = 0; r < 200; r++) rows.push([r, r + 1, [r * 2]]);
print(sum, a.length, rows.join(';').length);
