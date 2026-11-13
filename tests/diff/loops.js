let out = '';
for (let i = 0; i < 10; i++) { if (i % 2 === 0) continue; if (i > 7) break; out += i; }
print(out);
let j = 0; let w = '';
while (true) { j++; if (j === 2) continue; if (j > 4) break; w += j; }
print(w, j);
let pairs = '';
for (let a = 0; a < 3; a++) { for (let b = 0; b < 3; b++) { if (b === a) continue; if (b > 1) break; pairs += a + '' + b + ' '; } }
print(pairs);
let k = 0;
for (;;) { if (++k >= 5) break; }
print(k);
let m = 0;
for (m = 10; m > 0; m -= 3) {}
print(m);
let c = 0;
while (c < 3) { { { c++; continue; } } }
print(c);
for (let q = 0; q < 3; q++) { let fresh; print(fresh); fresh = q; }
