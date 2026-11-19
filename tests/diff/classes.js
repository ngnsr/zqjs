// M33 (D63): Classes, extends, super(), super.prop, static methods, and constructor rules.

class Animal {
    constructor(name) {
        this.name = name;
        this.makeGreet = () => "hi " + this.name;
    }
    speak() {
        return this.name + " speaks";
    }
    static kind() {
        return "Animal";
    }
    ["comp" + 1]() {
        return 42;
    }
}

class Dog extends Animal {
    constructor(name, breed) {
        try {
            this.x = 1;
        } catch (e) {
            print("tdz:", e.name);
        }
        super(name);
        this.breed = breed;
        try {
            super(name);
        } catch (e) {
            print("double-super:", e.name);
        }
    }
    speak() {
        return super.speak() + " (" + this.breed + ")";
    }
    superArrow() {
        const fn = () => super.speak();
        return fn();
    }
    static kind() {
        return super.kind() + "->Dog";
    }
}

const d = new Dog("Rex", "Lab");
print(d.name, d.breed, d.speak(), d.makeGreet(), d.comp1(), d.superArrow());
print(d instanceof Dog, d instanceof Animal, d instanceof Object);
print(Object.getPrototypeOf(Dog) === Animal, Dog.kind(), Animal.kind());
print(Object.keys(Animal.prototype).length, Object.keys(Dog.prototype).length);
print(Dog.name, Dog.length, Animal.name, Animal.length);

// Calling class without `new` throws TypeError
try {
    Animal("x");
} catch (e) {
    print("no-new:", e.name);
}

// Implicit default constructors (base and derived)
class BaseDefault {}
class SubDefault extends Animal {}
const bd = new BaseDefault();
const sd = new SubDefault("Max");
print(bd instanceof BaseDefault, sd.name, sd instanceof SubDefault, sd instanceof Animal);

// Derived constructor return rules
class RetObj extends Animal {
    constructor() {
        super("x");
        return { custom: true };
    }
}
class RetUndef extends Animal {
    constructor() {
        super("y");
        return undefined;
    }
}
class RetPrim extends Animal {
    constructor() {
        super("z");
        return 123;
    }
}
print(new RetObj().custom, new RetUndef().name);
try {
    new RetPrim();
} catch (e) {
    print("ret-prim:", e.name);
}

// Class expression + inner name + inferred name
const MyCls = class Inner {
    who() {
        return Inner.name;
    }
};
const Anon = class {};
print(MyCls.name, new MyCls().who(), Anon.name);

// extends null & extends Error
class NullBase extends null {}
print(Object.getPrototypeOf(NullBase.prototype), Object.getPrototypeOf(NullBase) === Function.prototype);

class MyError extends Error {
    constructor(msg) {
        super(msg);
        this.code = 99;
    }
}
const err = new MyError("boom");
print(err instanceof MyError, err instanceof Error, err.message, err.code);

// super.prop write & delete super.prop
class SupWrite extends Animal {
    test() {
        super.x = 7;
        print(this.x, super.x);
        try {
            delete super.x;
        } catch (e) {
            print("del-super:", e.name);
        }
    }
}
new SupWrite("W").test();
