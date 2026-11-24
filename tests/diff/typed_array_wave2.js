const TypedArray = globalThis.TypedArray || Object.getPrototypeOf(Uint8Array);

function errName(fn) {
    try {
        fn();
        return "OK";
    } catch (e) {
        return e.name;
    }
}

const nonIter = { [Symbol.iterator]: 123, length: 2, 0: 10, 1: 20 };
print("non-callable iterator:", errName(() => new Uint8Array(nonIter)));

const ab = new ArrayBuffer(8);
print("dv offset oob:", errName(() => new DataView(ab, 9)));
print("dv len oob:", errName(() => new DataView(ab, 4, 8)));

function CustomTA(len) {
    return new Int16Array(len);
}
const customOf = TypedArray.of.call(CustomTA, 5, 6);
print("custom of:", customOf.length, customOf[0], customOf[1]);
print("non-ctor of:", errName(() => TypedArray.of.call({}, 1, 2)));
