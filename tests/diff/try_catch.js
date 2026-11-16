// Basic throw / catch of arbitrary values.
try {
  throw 42;
} catch (e) {
  print('num:', e);
}

try {
  throw { code: 7, msg: 'oops' };
} catch (e) {
  print('obj:', e.code, e.msg);
}

// Binding-less catch.
try {
  throw 'ignored';
} catch {
  print('bare catch ok');
}

// Built-in TypeError / ReferenceError materialized with name + message.
try {
  let o = null;
  print(o.x);
} catch (e) {
  print('type:', e.name);
}

try {
  print(tdzVar);
  let tdzVar = 1;
} catch (e) {
  print('ref:', e.name);
}

// Nested try/catch and rethrow.
try {
  try {
    throw 'inner';
  } catch (e) {
    print('caught1:', e);
    throw e + '+outer';
  }
} catch (e2) {
  print('caught2:', e2);
}

// Multi-frame unwind from nested calls.
function leaf(n) {
  if (n <= 0) throw 'boom';
  return leaf(n - 1) + 1;
}
function mid() {
  return leaf(3);
}
try {
  print(mid());
} catch (e) {
  print('unwound:', e);
}

// Return inside try and catch.
function retTry() {
  try {
    return 'from-try';
  } catch (e) {
    return 'from-catch';
  }
}
function retCatch() {
  try {
    throw 'err';
  } catch (e) {
    return 'caught-' + e;
  }
}
print(retTry(), retCatch());

// Closures capturing catch bindings across loop iterations.
let fns = [];
for (let i = 0; i < 3; i++) {
  try {
    throw i * 10;
  } catch (e) {
    fns[i] = function () {
      e += 1;
      return e;
    };
  }
}
print(fns[0](), fns[0](), fns[1](), fns[2]());
