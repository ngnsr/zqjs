// for with continue (lands on the update), break, and a nested while.
let s = 0;
for (let i = 0; i < 10; i++) {
  if (i === 2) continue;
  if (i === 8) break;
  let j = i;
  while (j > 0) { s += j; j--; }
}
print(s);
