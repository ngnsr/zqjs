// Basic match, no match, fall-through
function basic(v) {
  let r = '';
  switch (v) {
    case 1:
      r += 'one,';
    case 2:
      r += 'two,';
      break;
    case 3:
      r += 'three';
      break;
    default:
      r += 'default';
  }
  return r;
}
print(basic(1), basic(2), basic(3), basic(99));

// No match and no default
let touched = false;
switch (5) {
  case 1:
    touched = true;
    break;
  case 2:
    touched = true;
}
print('touched:', touched);

// default first and middle with fall-through
function defFirst(v) {
  let r = '';
  switch (v) {
    default:
      r += 'D';
    case 1:
      r += '1';
      break;
    case 2:
      r += '2';
  }
  return r;
}
print(defFirst(0), defFirst(1), defFirst(2));

function defMiddle(v) {
  let r = '';
  switch (v) {
    case 1:
      r += '1';
    default:
      r += 'D';
    case 2:
      r += '2';
  }
  return r;
}
print(defMiddle(1), defMiddle(9), defMiddle(2));

// Strict equality: NaN, -0, type mismatch
switch (NaN) {
  case NaN:
    print('NaN matched');
    break;
  default:
    print('NaN not matched');
}
switch (-0) {
  case 0:
    print('-0 matched 0');
    break;
}
switch (0) {
  case -0:
    print('0 matched -0');
    break;
}
switch (1) {
  case '1':
    print('loose');
    break;
  default:
    print('strict');
}

// Lazy case evaluation with side effects
const evalLog = [];
function trace(n) {
  evalLog.push(n);
  return n;
}
switch (2) {
  case trace(1):
    print('matched 1');
    break;
  case trace(2):
    print('matched 2');
    break;
  case trace(3):
    print('matched 3');
    break;
}
print('evalLog:', evalLog.join(','));

// Single lexical scope across cases & TDZ
switch (1) {
  case 1:
    try {
      print(shared);
    } catch (e) {
      print('tdz:', e.name);
    }
    break;
  case 2:
    let shared = 42;
    break;
}
switch (2) {
  case 1:
    let x = 10;
  case 2:
    x = 20;
    print('x:', x);
}

// switch inside loops with break and continue
const loopOut = [];
for (let i = 0; i < 5; i++) {
  switch (i) {
    case 1:
      continue;
    case 3:
      break;
    default:
      loopOut.push('d' + i);
  }
  loopOut.push('a' + i);
}
print('loopOut:', loopOut.join(','));

// return from inside switch in a function
function retSwitch(x) {
  switch (x) {
    case 'a':
      return 100;
    default:
      return 200;
  }
}
print(retSwitch('a'), retSwitch('b'));

// Empty switch still evaluates discriminant
let discEval = 0;
switch (discEval = 7) {}
print('discEval:', discEval);
