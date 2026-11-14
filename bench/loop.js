// A hot numeric loop: locals, arithmetic, comparisons, branches, continue.
let s = 0;
for (let i = 0; i < 1000000; i++) { if (i % 3 === 0) continue; s += i * 2 - (i % 7); }
print(s);
