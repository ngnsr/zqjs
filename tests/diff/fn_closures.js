// Each execution of a block creates fresh captured bindings.
let a; let b;
{ let x = 1; a = function() { return x; }; }
{ let x = 2; b = function() { return x; }; }
print(a(), b());
// Two closures share one mutable variable that outlives the scope that created it.
let inc; let get;
{ let shared = 10; inc = function() { shared++; return shared; }; get = function() { return shared; }; }
inc(); inc(); print(get(), inc(), get());
// Independent instances of a counter.
function counter(start) { let n = start; return function() { n = n + 1; return n; }; }
const c1 = counter(0), c2 = counter(100);
c1(); c1(); print(c1(), c2(), c1());
// Closures created in a repeatedly executed block: one binding per execution.
let first; let last; let k = 0;
while (k < 3) { let v = k * 10; if (k === 0) first = function() { return v; }; last = function() { return v; }; k++; }
print(first(), last());
// Capturing through two levels (a capture of a capture), and writing through it.
function outer() {
  let depth = 'outer';
  function middle() { function inner() { depth = depth + '+inner'; return depth; } return inner; }
  return middle();
}
const deep = outer(); print(deep(), deep());
// A captured parameter, and a closure over a later-declared let used after it is initialised.
function adder(x) { return function(y) { return x + y; }; }
print(adder(2)(3), adder('a')('b'));
function later() { return late; }
let late = 'initialised';
print(later());
// Shadowing: a parameter, a local and a captured name with the same spelling.
let s = 'global s';
function shadow(s) { let t = function() { return s; }; { let s = 'block s'; print(s, t()); } return s; }
print(shadow('param s'), s);
