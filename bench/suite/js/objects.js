// Pure-JS benchmark: object creation, property reads/writes, prototype methods
// Iterations: 200,000
const proto = { scale: 2, area() { return this.w * this.h * this.scale; } };
let total = 0;
for (let i = 0; i < 200000; i++) {
  const r = Object.create(proto);
  r.w = i % 10;
  r.h = 3;
  let key = 'h';
  if (i % 2 === 0) key = 'w';
  total = total + r.area() + r[key];
}
print('RESULT', total);
