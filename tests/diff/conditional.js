print(true ? 1 : 2);
print(false ? 1 : 2);
print(true ? false ? 1 : 2 : 3);
print(false ? 1 : true ? 2 : 3);

let x = 0;
print(true ? x = 10 : x = 20, x);
print(false ? x = 30 : x = 40, x);

// Short-circuiting: unselected branch must not run.
let calls = 0;
function hit(v) {
  calls++;
  return v;
}
print(true ? hit('then') : hit('else'), calls);
print(false ? hit('then2') : hit('else2'), calls);

// Precedence: below || and &&, above assignment.
print(false || true ? 'yes' : 'no');
print(true && false ? 'yes' : 'no');
print(0 ? 1 : 2 || 3);
let y = false ? 1 : 2;
print(y);

// Truthiness edge cases.
print('' ? 1 : 2, NaN ? 1 : 2, null ? 1 : 2, undefined ? 1 : 2, [] ? 1 : 2, ({}) ? 1 : 2);

// `in` allowed inside `then` branch even in `for` initializer.
for (let ok = true ? 'a' in { a: 1 } : false; ok; ok = false) {
  print('for-in', ok);
}
