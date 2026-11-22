// Hoisting at top level
print(typeof topA, topA);
var topA = 10;
print(topA);
var topA;
print(topA);

// Hoisting inside functions across blocks, if(false), switch, try/finally
function hoistFn() {
  print(a, b, c, d);
  if (false) {
    var a = 1;
  }
  {
    var b = 2;
  }
  switch (1) {
    case 1:
      var c = 3;
      break;
  }
  try {
    var d = 4;
  } finally {
    var e = 5;
  }
  print(a, b, c, d, e);
}
hoistFn();

// Duplicate var & no-init var in loop must not reset value
function loopNoReset() {
  var acc = 0;
  for (var i = 0; i < 4; i++) {
    var acc;
    acc += i;
  }
  print(i, acc);
}
loopNoReset();

// var + parameter merging
function paramMerge(x, y) {
  var x;
  var y = y + 10;
  return x + y;
}
print(paramMerge(5, 7));

// var + function declaration in same scope
function fnVarMerge() {
  print(typeof f1, f1(), typeof f2, f2(), typeof f3, f3());
  var f1;
  function f1() { return 11; }
  function f2() { return 22; }
  var f2;
  function f3() { return 33; }
  var f3 = 99;
  print(f1(), f2(), f3);
}
fnVarMerge();

// Closures capture shared var in for / for-of / for-in (no per-iteration cloning)
function closureLoops() {
  var fns = [];
  for (var i = 0; i < 3; i++) {
    fns.push(() => i);
  }
  print(i, fns.map((f) => f()).join(","));

  var ofFns = [];
  for (var v of [10, 20, 30]) {
    ofFns.push(() => v);
  }
  print(v, ofFns.map((f) => f()).join(","));

  var inFns = [];
  for (var k in { p: 1, q: 2 }) {
    inFns.push(() => k);
  }
  print(k, inFns.map((f) => f()).join(","));
}
closureLoops();

// Destructuring & single-statement var
function destructAndSingle() {
  var { x, y = 5 } = { x: 1 };
  var [first, ...rest] = [7, 8, 9];
  if (true) var s1 = "yes";
  if (false) var s2 = "no";
  print(x, y, first, rest.join("-"), s1, s2);
}
destructAndSingle();

// Block-scoped let does not conflict with sibling var
function siblingLet() {
  {
    let m = "inner";
    print(m);
  }
  var m = "outer";
  print(m);
}
siblingLet();

// Class static block isolates var
var outerSb = "outside";
class Box {
  static {
    var outerSb = "inside";
    print(outerSb);
  }
}
print(outerSb);
