// String building: concatenation of numbers and literals (heap allocation per step).
let s = '';
let n = 0;
for (let i = 0; i < 20000; i++) { let piece = '' + i; s = piece + ','; n = n + 1; }
let t = 'x';
for (let j = 0; j < 12; j++) { t = t + t; }
print(n, s, t === t);
