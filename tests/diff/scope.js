let x = 'outer';
{ let x = 'inner'; print(x); { let x = 'innermost'; print(x); } print(x); }
print(x);
{ let a = 1; } { let b = 2; print(b); }
for (let i = 0; i < 2; i++) { let i = 'body'; print(i); }
let total = 0;
for (let i = 0; i < 3; i++) { for (let i = 10; i < 12; i++) { total += i; } total += i; }
print(total);
let undefined2 = undefined;
print(undefined2, NaN, Infinity, -Infinity);
{ let undefined = 'shadowed'; print(undefined); }
