// M31: Lexical `this` in arrow functions across constructors, methods, nested arrows, and call/apply/bind.

// 1. Constructor with arrow method
function Counter(start) {
    this.n = start;
    this.inc = () => ++this.n;
    this.add = (x) => {
        this.n += x;
        return this.n;
    };
}
const c = new Counter(10);
const inc = c.inc;
print("counter:", inc(), inc(), c.add(5), c.n);

// 2. Deeply nested arrows inside a method
const obj = {
    val: "outer",
    make() {
        return () => () => () => this.val;
    },
    withDefault(fn = () => this.val) {
        return fn();
    },
    mapItems(bias) {
        return [1, 2, 3].map(x => x + bias + this.offset);
    },
    offset: 100,
};
const deep = obj.make()()();
print("deep:", deep());
print("default:", obj.withDefault());
print("map:", obj.mapItems(10).join(","));

// 3. call / apply / bind cannot override lexical `this` on an arrow
const arrow = obj.make()()();
print("call:", arrow.call({ val: "other" }));
print("apply:", arrow.apply({ val: "other" }, []));
print("bind:", arrow.bind({ val: "other" })());

// 4. Inner non-arrow function gets its own `this`, and its arrow captures that inner `this`
const outerObj = {
    name: "outerObj",
    inner: {
        name: "innerObj",
        getArrow() {
            return () => this.name;
        },
    },
    run() {
        return this.inner.getArrow()();
    },
};
print("innerThis:", outerObj.run());
