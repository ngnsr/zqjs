function show(v) {
  if (v === undefined) return 'undefined';
  return JSON.stringify(v);
}

// Object.values & Object.entries
let obj = { b: 2, a: 1, 1: 'one', 0: 'zero' };
print(show(Object.values(obj)));
print(show(Object.entries(obj)));
print(show(Object.values('hi')), show(Object.entries('hi')));
print(show(Object.values(42)), show(Object.entries(true)));
print(show(Object.values([10, 20])), show(Object.entries([10, 20])));
let m = new Map([['k', 'v']]);
let st = new Set([1, 2]);
print(show(Object.values(m)), show(Object.entries(st)));

// Object.assign
let target = { a: 1, b: 2 };
let res = Object.assign(target, { b: 20, c: 30 }, null, undefined, 123, 'xy', m, st);
print(res === target, show(target));
for (let bad of [null, undefined]) {
  try {
    Object.assign(bad, { a: 1 });
  } catch (e) {
    print(e.name);
  }
}

// String(x) & Number(x)
print(show(String()), show(String(123)), show(String(-0)), show(String(null)), show(String(undefined)));
print(Number(), Number('  -42.5 '), Number('0x10'), Number(''), Number(null), Number(undefined), Number(true));

// parseInt
print(parseInt('0x1f'), parseInt('0X1F'), parseInt('  -12px'), parseInt('1e3'), parseInt('1e3', 16));
print(parseInt('101', 2), parseInt('zz', 36), parseInt('10', 0), parseInt('10', 1), parseInt('10', 37));
print(parseInt('0x10', 10), parseInt('0x10', 16), parseInt('-0'), 1 / parseInt('-0'));
print(parseInt('', 10), parseInt('   ', 10), parseInt('08', 8));

// parseFloat
print(parseFloat('.5e1x'), parseFloat('  -3.14abc'), parseFloat('1e'), parseFloat('1e+x'));
print(parseFloat('Infinity'), parseFloat('-Infinity'), parseFloat('0x10'), parseFloat(''));
print(1 / parseFloat('-0'));

// Number.* & global isNaN/isFinite
print(Number.isNaN(NaN), Number.isNaN('NaN'), Number.isNaN(undefined));
print(isNaN(NaN), isNaN('NaN'), isNaN(undefined), isNaN('123'));
print(Number.isFinite(42), Number.isFinite(Infinity), Number.isFinite('42'), Number.isFinite(NaN));
print(isFinite(42), isFinite(Infinity), isFinite('42'), isFinite(null));
print(Number.isInteger(0), Number.isInteger(-5.0), Number.isInteger(5.5), Number.isInteger(Infinity), Number.isInteger('5'));
print(Number.isSafeInteger(9007199254740991), Number.isSafeInteger(9007199254740992), Number.isSafeInteger(-9007199254740991), Number.isSafeInteger(1.5), Number.isSafeInteger('1'));
print(Number.MAX_SAFE_INTEGER, Number.MIN_SAFE_INTEGER, Number.EPSILON > 0, Number.MAX_VALUE > 1e300, Number.MIN_VALUE > 0);
print(Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY, Number.isNaN(Number.NaN));

// Array.from & Array.of
print(show(Array.of()), show(Array.of(1, 'a', true)));
print(show(Array.from('a😀b')));
print(show(Array.from(new Set([10, 20, 30]))));
print(show(Array.from([1, 2, 3], function (x, i) { return x + i + this.base; }, { base: 100 })));
print(show(Array.from(m, (kv) => kv[0] + '=' + kv[1])));
