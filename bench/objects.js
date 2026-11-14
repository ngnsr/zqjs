// Property access: object literals, named and computed reads/writes, method calls with
// `this`, and prototype-chain lookups.
const proto = { scale: 2, area() { return this.w * this.h * this.scale; } };
let total = 0;
for (let i = 0; i < 50000; i++) {
  const r = Object.create(proto);
  r.w = i % 10; r.h = 3;
  let key = 'h'; if (i % 2 === 0) key = 'w';
  total = total + r.area() + r[key];
}
print(total);
