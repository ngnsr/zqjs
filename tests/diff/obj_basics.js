// Objects: properties, key order (array indices first, ascending), delete, in.
let m = { b: 1, a: 2, 1: 'one', 0: 'zero', '2': 'two' };
print(Object.keys(m));
m.c = 3; delete m.b; m.b = 4;
print(Object.keys(m), m.b, m.missing, 'b' in m, 'missing' in m);
// "4294967294" is the largest index; "4294967295", "01", "-1" and "1.5" are ordinary keys.
let big = { x: 1, 4294967295: 'a', 4294967294: 'b', '01': 'c', '-1': 'd', 1.5: 'e', 7: 'f' };
print(Object.keys(big));
// Number keys are converted to strings: -0 is "0", 1e21 is "1e+21".
let nk = {}; nk[-0] = 'neg zero'; nk[1e21] = 'big'; nk[0.5] = 'half';
print(nk[0], nk['1e+21'], nk['0.5'], Object.keys(nk));
// Keywords are fine as property names; shorthand properties and methods.
let x = 'short';
let k = { if: 1, this: 2, x, f() { return this.if + this.this; } };
print(k.if, k.this, k.x, k.f());
// Duplicate keys: the last value, the first position.
let d = { a: 1, b: 2, a: 3 };
print(Object.keys(d), d.a);
// Identity and truthiness.
let o1 = {}, o2 = {};
print(o1 === o1, o1 === o2, !o1, delete o1.nothing, delete m.c, Object.keys(m));
