// Collection brand checks throw TypeError
function expectTypeError(label, fn) {
  try {
    fn();
    print(label, "NO_ERROR");
  } catch (e) {
    print(label, e.name);
  }
}

expectTypeError("Set.add", () => Set.prototype.add.call({}, 1));
expectTypeError("Set.has", () => Set.prototype.has.call([], 1));
expectTypeError("Set.size", () => Object.getOwnPropertyDescriptor(Set.prototype, "size").get.call({}));
expectTypeError("Map.get", () => Map.prototype.get.call([], 1));
expectTypeError("Map.set", () => Map.prototype.set.call({}, 1, 2));
expectTypeError("Map.size", () => Object.getOwnPropertyDescriptor(Map.prototype, "size").get.call({}));
expectTypeError("WeakMap.get", () => WeakMap.prototype.get.call({}, {}));
expectTypeError("WeakSet.add", () => WeakSet.prototype.add.call({}, {}));

// Number.parseFloat / Number.parseInt identity and behaviour
print("parseFloat id:", Number.parseFloat === parseFloat, Number.parseFloat("3.25px"));
print("parseInt id:", Number.parseInt === parseInt, Number.parseInt("0x10", 16));

// Generic Array.prototype.splice
const obj1 = { length: 3, 0: "a", 1: "b", 2: "c" };
const del1 = Array.prototype.splice.call(obj1, 1, 1, "x", "y");
print("del1:", del1.join(","), "obj1:", obj1[0], obj1[1], obj1[2], obj1[3], obj1.length);

const obj2 = { length: 4, 0: "p", 3: "s" };
const del2 = Array.prototype.splice.call(obj2, 1, 2);
print("del2:", del2.length, 0 in del2, 1 in del2, "obj2:", obj2[0], obj2[1], 2 in obj2, 3 in obj2, obj2.length);

expectTypeError("splice string", () => Array.prototype.splice.call("abc", 0, 1));
