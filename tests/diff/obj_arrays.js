// Dense arrays: index, length, push, pop, join, truncation, appending at the end.
let a = [10, 20, 30];
print(a.length, a[0], a[2], a[3], a[-1], a['1']);
a[3] = 40; a[a.length] = 50;
print(a, a.length);
print(a.push(60, 70), a.pop(), a.length);
a.length = 2;
print(a, a.length, a.join('-'), a.join(), [].join(), [1].join(', '));
let empty = [];
print(empty.pop(), empty.length);
// Keys and indices of arrays; nested arrays print flattened; null/undefined print empty.
let nested = [1, [2, [3, [4]]], null, undefined, 'x'];
print(nested, nested.length, Object.keys([7, 8, 9]), Array.isArray(nested), Array.isArray({}));
// Arrays can also have named properties (not listed among the elements).
let named = [1, 2]; named.extra = 'e';
print(named, named.extra, Object.keys(named));
// A cycle prints as empty where it recurses.
let cyc = [1, 2]; cyc.push(cyc);
print(cyc);
// delete past the end is a no-op; deleting length is refused.
print(delete named[5], delete named.length, named.length);
// Boolean(), Object() / new Object(), Array() / new Array(), void, globalThis.
print(Boolean(), Boolean(0), Boolean(""), Boolean(null), Boolean(undefined), Boolean(NaN), Boolean(1), Boolean("0"), Boolean({}));
print(true.toString(), false.toString(), true.valueOf(), false.valueOf(), Boolean.prototype.toString(), Boolean.prototype.valueOf(), true.constructor === Boolean);
print("hi".toString(), "hi".valueOf(), String.prototype.toString(), "".constructor === String);
let o0 = Object(), o1 = new Object(null), o2 = new Object(undefined), ref = { k: 9 };
print(typeof o0, typeof o1, typeof o2, Object(ref) === ref, new Object(ref) === ref, Object(Array) === Array);
let ar0 = Array(), ar1 = new Array(0), ar2 = Array("only"), ar3 = new Array(10, 20, 30);
print(ar0.length, ar1.length, ar2.length, ar2[0], ar3.join(","), ar3.constructor === Array);
try { Array(-1); } catch (e) { print(e.name); }
try { new Array(1.5); } catch (e) { print(e.name); }
let side = 0;
print(void 0, void (side += 7), side);
globalThis.customGlobal = 42;
print(globalThis === globalThis.globalThis, globalThis.Array === Array, globalThis.Boolean === Boolean, globalThis.customGlobal, Object.hasOwn(globalThis, "NaN"));
// Primitive wrappers, generic Array.prototype receivers, defineProperty on array index, private unicode escape.
let wb = new Boolean(true), wn = new Number(42), ws = new String("abc");
print(typeof wb, wb.valueOf(), wb + 1, typeof wn, wn.valueOf(), wn + 8, typeof ws, ws.valueOf(), ws.length, ws[1], Object.keys(ws).join(","));
print(Object(true) instanceof Boolean, Object(7) instanceof Number, Object("x") instanceof String);
let al = { 0: 10, 1: 20, 2: 30, length: 3 };
print(
  Array.prototype.reduce.call(al, (a, b) => a + b, 0),
  Array.prototype.reduceRight.call(al, (a, b) => a - b),
  Array.prototype.map.call(al, x => x / 10).join(","),
  Array.prototype.filter.call(al, x => x > 15).join(","),
  Array.prototype.some.call(al, x => x === 20),
  Array.prototype.every.call(al, x => x >= 10),
  Array.prototype.indexOf.call(al, 20),
  Array.prototype.lastIndexOf.call(al, 30),
  Array.prototype.includes.call(al, 10),
  Array.prototype.slice.call(al, 1).join(",")
);
let da = [1, 2];
Object.defineProperty(da, "1", { value: 99 });
Object.defineProperty(da, "2", { value: 100, writable: true, enumerable: true, configurable: true });
print(da.join(","), da.length);
class PrivEsc {
  #\u{6F} = 55;
  getO() { return this.#o; }
}
print(new PrivEsc().getO());
