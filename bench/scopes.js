// Block scope entry and TDZ: nested blocks with let/const in a loop (no closures).
let acc = 0;
for (let i = 0; i < 200000; i++) { let a = i; { const b = a + 1; { let c = b * 2; acc = acc + c - b; } } }
print(acc);
