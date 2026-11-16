function sameSignZero(x) {
  return x === 0 ? (1 / x < 0 ? "-0" : "+0") : String(x);
}

print(Math.E, Math.LN2, Math.LN10, Math.LOG2E, Math.LOG10E, Math.PI, Math.SQRT1_2, Math.SQRT2);

print(sameSignZero(Math.abs(-0)), Math.abs(-3.5), Math.abs("-4"), Math.abs(null), Math.abs(undefined), Math.abs(-Infinity));
print(sameSignZero(Math.floor(-0)), Math.floor(1.9), Math.floor(-1.1), Math.floor(NaN), Math.floor(Infinity), Math.floor(-Infinity));
print(sameSignZero(Math.ceil(-0)), sameSignZero(Math.ceil(-0.5)), Math.ceil(1.1), Math.ceil(-1.9), Math.ceil(NaN));
print(sameSignZero(Math.trunc(-0)), sameSignZero(Math.trunc(-0.9)), Math.trunc(3.9), Math.trunc(-3.9), Math.trunc(NaN));

print(
  sameSignZero(Math.round(0)),
  sameSignZero(Math.round(-0)),
  sameSignZero(Math.round(-0.2)),
  sameSignZero(Math.round(-0.5)),
  Math.round(-0.5000000000000001),
  Math.round(0.49999999999999994),
  Math.round(0.5),
  Math.round(-1.5),
  Math.round(4503599627370496),
  Math.round(-4503599627370496),
  Math.round(4503599627370497),
  Math.round(NaN),
  Math.round(Infinity),
  Math.round(-Infinity)
);

print(Math.min(), Math.max());
print(sameSignZero(Math.min(0, -0)), sameSignZero(Math.min(-0, 0)));
print(sameSignZero(Math.max(-0, 0)), sameSignZero(Math.max(0, -0)));
print(Math.min(3, -1, NaN, -10), Math.max(3, -1, NaN, 10));

print(Math.min("2", true, "-5"), Math.max("2", false, "-5"), Math.min(1, undefined, -5));

print(Math.pow(2, 10), Math.pow(2, 0.5) === Math.SQRT2, Math.pow(NaN, 0), Math.pow(1, Infinity), Math.pow(-1, Infinity), Math.pow(-8, 1 / 3));
print(sameSignZero(Math.sqrt(-0)), Math.sqrt(9), Math.sqrt(-1), Math.sqrt(Infinity));

print(sameSignZero(Math.sin(-0)), Math.cos(0), sameSignZero(Math.tan(-0)));
print(sameSignZero(Math.asin(-0)), Math.acos(1), sameSignZero(Math.atan(-0)));
print(sameSignZero(Math.atan2(0, 1)), sameSignZero(Math.atan2(-0, 1)), Math.atan2(0, -1) === Math.PI, Math.atan2(-0, -1) === -Math.PI);
print(Math.log(1), Math.log(Math.E), Math.log(0), Math.log(-1), Math.exp(0), Math.exp(-Infinity), Math.exp(Infinity));

print(
  sameSignZero(Math.sign(0)),
  sameSignZero(Math.sign(-0)),
  Math.sign(42),
  Math.sign(-42),
  Math.sign(NaN),
  Math.sign(Infinity),
  Math.sign(-Infinity),
  Math.sign("-3.5")
);

print(Math.clz32(0), Math.clz32(1), Math.clz32(-1), Math.clz32(65536), Math.clz32(NaN), Math.clz32(Infinity));
print(Math.imul(2, 4), Math.imul(-1, 8), Math.imul(4294967295, 5), Math.imul(4294967294, 5));
print(sameSignZero(Math.fround(-0)), Math.fround(1.5), Math.fround(1.337) === 1.337, Math.fround(NaN), Math.fround(Infinity));

print(
  sameSignZero(Math.hypot()),
  sameSignZero(Math.hypot(-0, 0)),
  Math.hypot(3, 4),
  Math.hypot(3, 4, 12),
  Math.hypot(Infinity, NaN),
  Math.hypot(NaN, -Infinity),
  Math.hypot(1, NaN)
);
