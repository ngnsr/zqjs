// Base and computed key are evaluated exactly once, in order, for every member form.
let log = '';
function k(name) { log += 'k' + name + ' '; return name; }
function b(o) { log += 'b '; return o; }
let o = { x: 10, y: 1, n: 5 };
b(o)[k('x')] += 5;            print(o.x, log); log = '';
print(b(o)[k('y')]++, o.y, log); log = '';      // postfix: old value
print(++b(o)[k('y')], o.y, log); log = '';      // prefix: new value
print(b(o)[k('n')]--, --b(o)[k('n')], o.n, log); log = '';
print(b(o).x++, ++b(o).x, b(o).x -= 3, log); log = '';
// Computed keys in literals: each key, then its value, left to right.
function v(x) { log += 'v' + x + ' '; return x; }
let lit = { [k('a')]: v(1), [k('b')]: v(2), c: v(3) };
print(Object.keys(lit), lit.a + lit.b + lit.c, log); log = '';
// Assignment: base, key, then the right-hand side.
b(o)[k('z')] = v(7); print(o.z, log); log = '';
// Method calls keep their receiver; arguments come after the callee lookup.
let counter = { n: 0, add(d) { this.n += d; return this; } };
counter.add(1).add(2)['add'](3);
print(counter.n);
