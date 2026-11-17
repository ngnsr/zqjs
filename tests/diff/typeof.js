// Every value kind
print(typeof undefined);
print(typeof null);
print(typeof true, typeof false);
print(typeof 0, typeof -0, typeof NaN, typeof Infinity, typeof 42);
print(typeof '', typeof 'abc');
print(typeof {}, typeof []);
print(typeof new Map(), typeof new Set());
print(typeof new Promise(() => {}));
print(typeof [].values());
print(typeof function () {}, typeof (() => {}));
print(typeof print, typeof Object, typeof Math, typeof JSON);

// Undeclared names do not throw ReferenceError
print(typeof undeclaredName);
print(typeof (undeclaredName));

// Undeclared inside an expression still throws ReferenceError
try {
  typeof (undeclaredName + 1);
  print('no error');
} catch (e) {
  print(e.name);
}

// TDZ still throws ReferenceError
{
  try {
    print(typeof tdzVar);
  } catch (e) {
    print('tdz:', e.name);
  }
  let tdzVar = 1;
  print('after:', typeof tdzVar);
}

// TDZ via closure
{
  const f = () => typeof late;
  try {
    f();
  } catch (e) {
    print('closure tdz:', e.name);
  }
  const late = 10;
  print('closure after:', f());
}

// Precedence
print(typeof 1 + 2);
print(!typeof 0, !typeof '');
print(typeof typeof 1);
print(typeof -1, typeof !0);
