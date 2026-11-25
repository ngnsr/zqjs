// Array iterator, RegExp.prototype, and Array.prototype receiver edge cases.

const it = [10, 20][Symbol.iterator]();
const derived = Object.create(it);
let threwIter = false;
try {
  derived.next();
} catch (e) {
  threwIter = e instanceof TypeError;
}
print("iter_non_own_slot_typeerror:", threwIter);

let threwRxExec = false;
try {
  RegExp.prototype.exec("abc");
} catch (e) {
  threwRxExec = e instanceof TypeError;
}
let threwRxTest = false;
try {
  RegExp.prototype.test("abc");
} catch (e) {
  threwRxTest = e instanceof TypeError;
}
print("regexp_proto_exec_test_typeerror:", threwRxExec, threwRxTest);

let threwSpliceNull = false;
try {
  Array.prototype.splice.call(null, 0, 1);
} catch (e) {
  threwSpliceNull = e instanceof TypeError;
}
print("array_splice_null_typeerror:", threwSpliceNull);
