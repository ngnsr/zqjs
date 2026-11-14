// Members: base and key once (dup / dup2), postfix keeps the old value under them
// (rot3 / rot4); literals key-then-value; method calls pass the receiver.
let o = { a: 1, 'b': 2, [o]: 3, m() { return this.a; } };
o.a += 1;
o['b']++;
print(o.m(), [o.a, o.b], 'a' in o, delete o.a);
