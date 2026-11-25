// Promise conformance: callback lengths, SpeciesConstructor in then(),
// custom .then on Promise instances, Promise.prototype.catch delegation,
// and combinator abrupt resolve-capability handling.

// 1. Callback .length in Promise.all / allSettled / any / finally
let lengths = [];
const probe = {
    then(f, r) {
        lengths.push([f ? f.length : -1, r ? r.length : -1]);
        f(1);
    },
};
Promise.all([probe]);
Promise.allSettled([probe]);
Promise.any([probe]);
Promise.prototype.finally.call(
    {
        then(f, r) {
            lengths.push([f.length, r.length]);
            return "ok";
        },
    },
    () => {}
);
print("cb lengths:", lengths.map((p) => p.join(":")).join(" "));

// 2. Promise.prototype.then uses SpeciesConstructor + NewPromiseCapability
class SubPromise extends Promise {
    constructor(exec) {
        super(exec);
        this.tag = "sub";
    }
}
const pBase = Promise.resolve(10);
pBase.constructor = { [Symbol.species]: SubPromise };
const pSub = pBase.then((v) => v + 5);
print("species sub:", pSub instanceof SubPromise, pSub.tag);
pSub.then((v) => print("species val:", v));

// 3. resolvePromiseValue respects custom .then on a Promise instance
const customP = Promise.resolve("orig");
customP.then = function (res) {
    res("overridden");
};
new Promise((resolve) => resolve(customP)).then((v) => print("custom then:", v));

// 4. Promise.prototype.catch invokes .then observably
const seq = [];
const rej = Promise.reject("boom");
rej.then = function () {
    seq.push("then");
    return Promise.prototype.then.apply(this, arguments);
};
rej.catch((e) => {
    seq.push("catch:" + e);
    print("catch seq:", seq.join(","));
});

// 5. Combinator rejects returned promise when resolve capability throws
let rejVal = null;
function ThrowResolveCtor(exec) {
    exec(
        () => {
            throw new RangeError("cap-boom");
        },
        (e) => {
            rejVal = e.name + ":" + e.message;
        }
    );
}
ThrowResolveCtor.resolve = (v) => v;
Promise.all.call(ThrowResolveCtor, []);
print("cap throw:", rejVal);
