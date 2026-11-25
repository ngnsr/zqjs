// Exact IEEE-754 decimal formatting for Number.prototype.{toFixed, toExponential, toPrecision}.

const fixedCases = [
    [0, 0],
    [-0, 0],
    [-0, 2],
    [-0.0001, 0],
    [-0.0001, 2],
    [-0.005, 2],
    [0.5, 0],
    [2.5, 0],
    [0.005, 2],
    [99.9, 0],
    [1000000000000000128, 0],
    [1e20, 0],
    [1e21, 0],
    [Number.MIN_VALUE, 100],
    [5e-101, 100],
];
for (const [n, d] of fixedCases) {
    print("fixed:", n, d, n.toFixed(d));
}

const expCases = [
    [0, undefined],
    [-0, undefined],
    [0, 0],
    [0, 3],
    [25, 0],
    [123.456, 0],
    [123.456, 3],
    [123.456, 17],
    [123.456, 20],
    [-123.456, 17],
    [0.0001, 17],
    [0.9999, 0],
    [0.9999, 17],
    [Number.MAX_VALUE, 25],
    [Number.MIN_VALUE, 25],
];
for (const [n, d] of expCases) {
    print("exp:", n, d, d === undefined ? n.toExponential() : n.toExponential(d));
}

const precCases = [
    [0, 1],
    [-0, 3],
    [9.999999e-7, 1],
    [0.00000099, 1],
    [99.9, 2],
    [99.9, 3],
    [1.2345e27, 4],
    [1.2345e27, 18],
    [1.2345e27, 21],
    [-1.2345e27, 4],
    [1e-21, 16],
    [1e-21, 21],
];
for (const [n, p] of precCases) {
    print("prec:", n, p, n.toPrecision(p));
}
