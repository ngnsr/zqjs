// 1. Parenthesized LHS must not trigger SetFunctionName on anonymous function/class RHS
var f1;
(f1) = function() {};
print("f1:", JSON.stringify(f1.name));

var f2;
((f2)) = () => {};
print("f2:", JSON.stringify(f2.name));

var f3;
(f3) = class {};
print("f3:", JSON.stringify(f3.name));

var f4;
f4 = function() {};
print("f4:", JSON.stringify(f4.name));

var f5;
f5 = (function() {});
print("f5:", JSON.stringify(f5.name));

var f6;
(f6) ||= function() {};
print("f6:", JSON.stringify(f6.name));

var f7;
f7 ||= function() {};
print("f7:", JSON.stringify(f7.name));

var f8 = 1;
(f8) &&= function() {};
print("f8:", JSON.stringify(f8.name));

var f9;
(f9) ??= function() {};
print("f9:", JSON.stringify(f9.name));

// 2. `await` as identifier/shorthand/label inside arrow body nested in class static block
class C1 {
  static {
    let fn = () => ({ await });
    print("C1:", typeof fn);
  }
}

class C2 {
  static {
    let fn = () => {
      await: {
        break await;
      }
      return 42;
    };
    print("C2:", fn());
  }
}

// 3. `var n` inside named function expression `function n()` shadows the outer function name
var n = "outside";
var probeBefore = function() { return n; };
var probeBody;
var func = function n() {
  var n;
  probeBody = function() { return n; };
};
func();
print("scope-var-open:", probeBefore(), String(probeBody()));

var func2 = function m() {
  {
    var m = 99;
  }
  return m;
};
print("scope-var-block:", func2());

var func3 = function k() {
  return typeof k;
};
print("fn-name-still-works:", func3());
