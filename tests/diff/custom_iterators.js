function catchName(fn) {
    try {
        fn();
        return "NO_THROW";
    } catch (e) {
        return e.name;
    }
}

function makeRange(start, end, log) {
    return {
        [Symbol.iterator]() {
            let cur = start;
            return {
                next() {
                    if (cur <= end) return { value: cur++, done: false };
                    return { value: undefined, done: true };
                },
                return() {
                    if (log) log.push("return:" + cur);
                    return { done: true };
                },
            };
        },
    };
}

// 1. Custom iterable in for...of, array/call/new/super spread, destructuring
const collected = [];
for (const x of makeRange(1, 3)) collected.push(x);
print("for-of:", collected.join(","));
print("arr-spread:", [0, ...makeRange(1, 3), 4].join(","));

function takeArgs(a, b, c, d) {
    return [a, b, c, d].join(",");
}
print("call-spread:", takeArgs(10, ...makeRange(20, 22)));
const objCall = {
    base: 100,
    sum(a, b, c) { return this.base + a + b + c; },
};
print("method-spread:", objCall.sum(...makeRange(1, 3)));

class ParentCtor {
    constructor(...args) {
        this.args = args;
    }
}
class ChildCtor extends ParentCtor {
    constructor() {
        super(9, ...makeRange(10, 12));
    }
}
print("new-spread:", new ParentCtor(...makeRange(5, 7)).args.join(","));
print("super-spread:", new ChildCtor().args.join(","));

const [da, db, ...drest] = makeRange(1, 5);
print("destruct:", da, db, drest.join(","));

// 2. Class with [Symbol.iterator]()
class Countdown {
    constructor(n) {
        this.n = n;
    }
    [Symbol.iterator]() {
        let cur = this.n;
        return {
            next() {
                if (cur > 0) return { value: cur--, done: false };
                return { done: true };
            },
        };
    }
}
print("class-iter:", [...new Countdown(4)].join(","));

// 3. Built-ins accepting custom iterables
print("Array.from:", Array.from(makeRange(1, 4)).join(","));
print("Array.from map:", Array.from(makeRange(1, 3), x => x * 10).join(","));

const fromThrowLog = [];
print("Array.from throw:", catchName(() => Array.from(makeRange(1, 5, fromThrowLog), x => {
    if (x === 2) throw new Error("stop");
    return x;
})), fromThrowLog.join(","));

const kvIter = {
    [Symbol.iterator]() {
        let i = 0;
        const pairs = [["a", 1], ["b", 2]];
        return {
            next() {
                if (i < pairs.length) return { value: pairs[i++], done: false };
                return { done: true };
            },
        };
    },
};
const mFromCustom = new Map(kvIter);
print("Map:", mFromCustom.size, mFromCustom.get("a"), mFromCustom.get("b"));

const badMapLog = [];
const badMapIter = {
    [Symbol.iterator]() {
        return {
            next() { return { value: 42, done: false }; },
            return() { badMapLog.push("closed"); return {}; },
        };
    },
};
print("Map bad entry:", catchName(() => new Map(badMapIter)), badMapLog.join(","));

const sFromCustom = new Set(makeRange(10, 12));
print("Set:", sFromCustom.size, [...sFromCustom].join(","));

const agg = new AggregateError(makeRange(10, 12), "agg");
print("AggErr:", agg.message, agg.errors.join(","));

// 4. Built-in [Symbol.iterator] identities and behavior
print("builtin ids:",
    [][Symbol.iterator] === Array.prototype.values,
    new Map()[Symbol.iterator] === Map.prototype.entries,
    new Set()[Symbol.iterator] === Set.prototype.values,
    typeof ""[Symbol.iterator]
);
const strIt = "a\uD83D\uDE00b"[Symbol.iterator]();
print("str-iter:", strIt[Symbol.iterator]() === strIt, strIt.next().value, strIt.next().value.length, strIt.next().value, strIt.next().done);

const customArr = [1, 2, 3];
customArr[Symbol.iterator] = function () {
    let i = this.length - 1;
    const self = this;
    return {
        next() {
            if (i >= 0) return { value: self[i--] * 10, done: false };
            return { done: true };
        },
    };
};
print("override arr:", [...customArr].join(","));

const customBuiltInIt = [1, 2, 3].values();
customBuiltInIt.next = function () {
    return { value: 99, done: true };
};
print("override next:", [...customBuiltInIt].join(","));

// 5. Edge cases: next cached once, value not read on done:true, errors
let nextCalls = 0;
let getterCalls = 0;
const cachedNextIter = {
    [Symbol.iterator]() {
        const it = {
            next() {
                nextCalls++;
                if (nextCalls === 1) {
                    it.next = function () { throw new Error("mutated next should not run"); };
                    return { value: "first", done: false };
                }
                return {
                    done: true,
                    get value() {
                        getterCalls++;
                        return "nope";
                    },
                };
            },
        };
        return it;
    },
};
print("cache next:", [...cachedNextIter].join(","), nextCalls, getterCalls);

print("non-iter for-of:", catchName(() => { for (const x of {}) {} }));
print("non-iter map:", catchName(() => new Map({})));
print("non-iter set:", catchName(() => new Set({})));
print("bad sym.iter:", catchName(() => [...{ [Symbol.iterator]: 123 }]));
print("prim iter:", catchName(() => [...{ [Symbol.iterator]() { return 42; } }]));
print("bad next:", catchName(() => [...{ [Symbol.iterator]() { return { next: 7 }; } }]));
print("prim res:", catchName(() => [...{ [Symbol.iterator]() { return { next() { return 9; } }; } }]));

const noCloseOnNextThrow = [];
print("next throws:", catchName(() => {
    for (const x of {
        [Symbol.iterator]() {
            return {
                next() { throw new RangeError("boom"); },
                return() { noCloseOnNextThrow.push("closed"); return {}; },
            };
        },
    }) {}
}), noCloseOnNextThrow.join(","));

const noCloseOnValueThrow = [];
print("value getter throws:", catchName(() => {
    for (const x of {
        [Symbol.iterator]() {
            return {
                next() {
                    return {
                        done: false,
                        get value() { throw new RangeError("valboom"); },
                    };
                },
                return() { noCloseOnValueThrow.push("closed"); return {}; },
            };
        },
    }) {}
}), noCloseOnValueThrow.join(","));

// 6. Built-in iterator continues after break
const builtinIt = [10, 20, 30].values();
let firstVal = 0;
for (const x of builtinIt) {
    firstVal = x;
    break;
}
print("builtin after break:", firstVal, builtinIt.next().value, builtinIt.next().value, builtinIt.next().done);

// 7. IteratorClose exhaustive tests
// 7a. Exhaustion does not call return()
const exhLog = [];
for (const x of makeRange(1, 3, exhLog)) exhLog.push("body:" + x);
print("exhausted:", exhLog.join(","));

// 7b. break in for...of calls return()
const brkLog = [];
for (const x of makeRange(1, 5, brkLog)) {
    brkLog.push("body:" + x);
    if (x === 2) break;
}
print("break:", brkLog.join(","));

// 7c. return in for...of calls return() and preserves return value
const retLog = [];
function retFn() {
    for (const x of makeRange(1, 5, retLog)) {
        retLog.push("body:" + x);
        if (x === 2) return { answer: 42 };
    }
    return { answer: 0 };
}
print("return:", retFn().answer, retLog.join(","));

// 7d. throw in for...of calls return()
const thrLog = [];
print("throw:", catchName(() => {
    for (const x of makeRange(1, 5, thrLog)) {
        thrLog.push("body:" + x);
        throw new Error("bodyErr");
    }
}), thrLog.join(","));

// 7e. labelled break & continue outer
const lblLog = [];
outer: for (const a of makeRange(1, 3, lblLog)) {
    lblLog.push("a:" + a);
    for (const b of makeRange(10, 13, lblLog)) {
        lblLog.push("b:" + b);
        if (b === 11 && a === 1) continue outer;
        if (b === 10 && a === 2) break outer;
    }
}
print("labelled:", lblLog.join(","));

// 7f. try...finally inside vs outside for...of
const finInLog = [];
function finInside() {
    for (const x of makeRange(1, 4, finInLog)) {
        try {
            finInLog.push("try:" + x);
            return "retVal";
        } finally {
            finInLog.push("fin");
        }
    }
}
print("finInside:", finInside(), finInLog.join(","));

const finOutLog = [];
function finOutside() {
    try {
        for (const x of makeRange(1, 4, finOutLog)) {
            finOutLog.push("body:" + x);
            return "retOut";
        }
    } finally {
        finOutLog.push("outerFin");
    }
}
print("finOutside:", finOutside(), finOutLog.join(","));

// 7g. Partial & empty array destructuring vs exhausted & rest
const p1Log = [];
const [pa] = makeRange(1, 4, p1Log);
print("partial:", pa, p1Log.join(","));

const empLog = [];
const [] = makeRange(1, 4, empLog);
print("empty:", empLog.join(","));

const exhPatLog = [];
const [ea, eb, ec] = makeRange(1, 2, exhPatLog);
print("exhPat:", ea, eb, ec, exhPatLog.join(","));

const restPatLog = [];
const [ra, ...rr] = makeRange(1, 3, restPatLog);
print("restPat:", ra, rr.join(","), restPatLog.join(","));

const defThrowLog = [];
print("defThrow:", catchName(() => {
    const [dx = (() => { throw new ReferenceError("def"); })()] = {
        [Symbol.iterator]() {
            return {
                next() { return { value: undefined, done: false }; },
                return() { defThrowLog.push("closed"); return {}; },
            };
        },
    };
}), defThrowLog.join(","));

const setThrowLog = [];
print("setThrow:", catchName(() => {
    const holder = { set x(v) { throw new TypeError("setter"); } };
    [holder.x] = makeRange(1, 3, setThrowLog);
}), setThrowLog.join(","));

// 7h. Nested destructuring error propagation
const nestOuter = [];
const nestInner = [];
print("nestedDest:", catchName(() => {
    const [[ni = (() => { throw new SyntaxError("inner"); })()]] = {
        [Symbol.iterator]() {
            return {
                next() {
                    return {
                        value: {
                            [Symbol.iterator]() {
                                return {
                                    next() { return { value: undefined, done: false }; },
                                    return() { nestInner.push("innerRet"); return {}; },
                                };
                            },
                        },
                        done: false,
                    };
                },
                return() { nestOuter.push("outerRet"); return {}; },
            };
        },
    };
}), nestInner.join(","), nestOuter.join(","));

// 7i. Error precedence in IteratorClose
function makeReturnThrower(err, retVal, usePrim) {
    return {
        [Symbol.iterator]() {
            return {
                next() { return { value: 1, done: false }; },
                return() {
                    if (usePrim) return retVal;
                    throw err;
                },
            };
        },
    };
}
print("both throw:", (() => {
    try {
        for (const x of makeReturnThrower(new TypeError("ret"))) {
            throw new RangeError("orig");
        }
    } catch (e) {
        return e.name + ":" + e.message;
    }
    return "NONE";
})());

print("break nonObj ret:", catchName(() => {
    for (const x of makeReturnThrower(null, 123, true)) break;
}));

print("destruct nonObj ret:", catchName(() => {
    const [x] = makeReturnThrower(null, "bad", true);
}));

print("throw ignores nonObj ret:", (() => {
    try {
        for (const x of makeReturnThrower(null, 123, true)) {
            throw new RangeError("kept");
        }
    } catch (e) {
        return e.name + ":" + e.message;
    }
    return "NONE";
})());

// 7j. Built-in iterator with custom throwing .return() called only once on return
let customBuiltinRetCalls = 0;
function builtinRetThrowsOnce() {
    const it = [1, 2, 3].values();
    it.return = function () {
        customBuiltinRetCalls++;
        throw new RangeError("once");
    };
    for (const x of it) {
        return x;
    }
    return 0;
}
print("builtin ret once:", catchName(builtinRetThrowsOnce), customBuiltinRetCalls);

// 8. Promise combinators with custom iterables
Promise.all([
    Promise.all(makeRange(1, 3)),
    Promise.allSettled(makeRange(4, 5)),
    Promise.race(makeRange(7, 9)),
    Promise.any(makeRange(11, 13)),
]).then(([allRes, settledRes, raceRes, anyRes]) => {
    print("pAll:", allRes.join(","));
    print("pSettled:", settledRes.map(r => r.status + ":" + r.value).join(","));
    print("pRace:", raceRes);
    print("pAny:", anyRes);
});
