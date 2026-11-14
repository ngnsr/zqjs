// `this` is the receiver of the call expression, not where the function was defined.
function getName() { return this.name; }
let a = { name: 'a', getName };
let b = { name: 'b', getName: a.getName };
print(a.getName(), b.getName(), a['getName']());
// A function created inside a method still takes `this` from its own call.
let outer = {
  name: 'outer',
  make() { let inner = { name: 'inner', get: function () { return this.name; } }; return inner.get(); },
};
print(outer.make());
// Methods on prototypes see the object they were called on.
let base = { describe() { return this.kind + ':' + this.size; } };
let thing = Object.create(base); thing.kind = 'box'; thing.size = 3;
print(thing.describe());
// Native methods use their receiver too.
let arr = [3, 4];
let push = arr.push;
let other = [1];
other.push2 = push;
print(other.push2(9), other);
