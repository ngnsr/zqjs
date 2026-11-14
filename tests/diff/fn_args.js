// Missing arguments are undefined; extra ones are evaluated (left to right) and dropped.
function two(a, b) { return a + '|' + b; }
print(two(1), two(1, 2), two(1, 2, print('extra evaluated')));
print(two(print('first'), print('second')));
// return; return value; falling off the end.
function none() {}
function early(x) { if (x) return; return 'late'; }
print(none(), early(true), early(false));
// return from inside nested blocks and loops.
function find(limit) {
  for (let i = 0; i < 10; i++) {
    let j = 0;
    while (true) { if (i * j > limit) { return i + ',' + j; } j++; if (j > 5) break; }
  }
  return 'not found';
}
print(find(12), find(1000));
// Parameters are ordinary mutable bindings; a body `let` may shadow inside a block.
function params(p, q) { p = p * 2; q += 1; { let p = 'inner'; print(p); } return p + q; }
print(params(3, 4));
// Function values: identity, truthiness, conversions that don't need source text.
function f() {} function g() {}
let h = f;
print(f === h, f === g, f !== g, !f, !!f, -f, f < 1, null < f);
