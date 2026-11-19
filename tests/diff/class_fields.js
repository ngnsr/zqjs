// 1. Public fields, computed keys, reserved-ish field names, DefineOwnProperty semantics
let k = "comp";
class ProtoWithSetter {
    set x(v) { print("SHOULD NOT CALL SETTER", v); }
}
class Pub extends ProtoWithSetter {
    x = 10;
    y;
    [k] = this.x + 5;
    static = 1;
    get = 2;
    set = 3;
    constructor(z) {
        super();
        print("in ctor:", this.x, this.y, this[k], this.static, this.get, this.set, z);
    }
}
let p = new Pub(99);
print("keys:", Object.keys(p));

// 2. Derived field initialization order + super.m() in field initializer
class Base {
    baseField = "base:" + this.tag();
    tag() { return "Base"; }
    m() { return 100; }
}
class Sub extends Base {
    subField = super.m() + 23;
    tag() { return "Sub"; }
    constructor() {
        super();
        print("after super:", this.baseField, this.subField);
    }
}
new Sub();

// 3. Private fields, methods, getters/setters, compound/update/logical assign, optional chain, #x in obj
class Box {
    #v = 10;
    #uninit;
    #helper(d) { return this.#v + d; }
    get #val() { return this.#v * 2; }
    set #val(x) { this.#v = x; }

    read() { return [this.#v, this.#uninit, this.#helper(5), this.#val]; }
    mutate() {
        this.#v += 3;
        this.#v++;
        this.#uninit ??= 77;
        this.#val = 20;
        let tmp = {};
        [this.#v] = [42];
        return [this.#v, this.#uninit, tmp];
    }
    static check(o) {
        return #v in o;
    }
    static readOther(o) {
        return o?.#v;
    }
}
let b = new Box();
print("box read:", b.read());
print("box mutate:", b.mutate()[0], b.mutate()[1]);
print("brand check:", Box.check(b), Box.check({}), Box.readOther(null), Box.readOther(b));
try { Box.check(1); print("no-throw"); } catch (e) { print("prim in:", e.name); }
try { Box.readOther({}); print("no-throw"); } catch (e) { print("wrong brand:", e.name); }

// 4. Distinct brands per class evaluation
function makeSecret(init) {
    return class {
        #s = init;
        get(o) { return o.#s; }
    };
}
let S1 = makeSecret(1);
let S2 = makeSecret(2);
let s1 = new S1();
let s2 = new S2();
print("same brand:", s1.get(s1), s2.get(s2));
try { s1.get(s2); print("no-throw"); } catch (e) { print("diff brand:", e.name); }

// 5. Static fields, static private members, and static {} blocks in source order
class ConfigBase {
    static baseVal() { return 50; }
}
class Config extends ConfigBase {
    static a = 1;
    static #secret = 10;
    static #double() { return this.#secret * 2; }
    static get #acc() { return this.#secret + 1; }
    static set #acc(v) { this.#secret = v; }
    static {
        this.b = this.a + this.#double();
        this.#acc = 30;
        this.c = this.#acc + super.baseVal();
    }
    static d = this.c + 1;
}
print("static:", Config.a, Config.b, Config.c, Config.d);

// 6. Closures & arrows inside field initializers
let ext = 7;
class ClosureField {
    #p = 5;
    fn = () => this.#p + ext;
}
print("closure field:", new ClosureField().fn());
