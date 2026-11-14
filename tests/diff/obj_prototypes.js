// Prototype chains: inherited reads, own writes, `in` follows the chain, keys don't.
let proto = { x: 10, greet() { return 'hi ' + this.name; } };
let obj = Object.create(proto);
obj.name = 'obj';
print(obj.x, 'x' in obj, Object.keys(obj).length, obj.greet());
obj.x = 20;
print(obj.x, proto.x, Object.keys(obj));
delete obj.x;
print(obj.x);
// Longer chains and null prototypes.
let c3 = Object.create(Object.create(proto));
print(c3.x, Object.getPrototypeOf(Object.getPrototypeOf(c3)) === proto);
let bare = Object.create(null);
bare.k = 1;
print(bare.k, 'toString' in bare, Object.getPrototypeOf(bare), Object.keys(bare));
// Built-in prototypes: methods come from them, and they are not enumerable.
print(Object.getPrototypeOf([]) === Object.getPrototypeOf([1]), Object.keys(Object.getPrototypeOf([])).length);
print('push' in [], 'toString' in {}, 'nothing' in {});
