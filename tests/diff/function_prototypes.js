// Generator, async generator and async function prototypes (M38, D68)
const P = Object.getPrototypeOf;
function* gen() {}
async function* agen() {}
async function afn() {}
const aarrow = async () => {};
const obj = { *g() {}, async *ag() {}, async am() {} };
class K { *g() {} async *ag() {} static async sm() {} }

const GeneratorFunctionPrototype = P(gen);
const AsyncGeneratorFunctionPrototype = P(agen);
const AsyncFunctionPrototype = P(afn);
const GeneratorPrototype = GeneratorFunctionPrototype.prototype;
const AsyncGeneratorPrototype = AsyncGeneratorFunctionPrototype.prototype;
const AsyncIteratorPrototype = P(AsyncGeneratorPrototype);
const IteratorPrototype = P(GeneratorPrototype);

print("distinct:", GeneratorFunctionPrototype !== Function.prototype, AsyncGeneratorFunctionPrototype !== Function.prototype,
  AsyncFunctionPrototype !== Function.prototype, GeneratorFunctionPrototype !== AsyncGeneratorFunctionPrototype);
print("inherit Function.prototype:", P(GeneratorFunctionPrototype) === Function.prototype,
  P(AsyncGeneratorFunctionPrototype) === Function.prototype, P(AsyncFunctionPrototype) === Function.prototype);
print("same kind, same proto:", P(obj.g) === GeneratorFunctionPrototype, P(K.prototype.g) === GeneratorFunctionPrototype,
  P(obj.ag) === AsyncGeneratorFunctionPrototype, P(K.prototype.ag) === AsyncGeneratorFunctionPrototype,
  P(aarrow) === AsyncFunctionPrototype, P(obj.am) === AsyncFunctionPrototype, P(K.sm) === AsyncFunctionPrototype);
print("plain functions:", P(function () {}) === Function.prototype, P(() => {}) === Function.prototype, P(K) === Function.prototype);

print("constructor links:", GeneratorPrototype.constructor === GeneratorFunctionPrototype,
  AsyncGeneratorPrototype.constructor === AsyncGeneratorFunctionPrototype);
print("prototype chains:", P(gen.prototype) === GeneratorPrototype, P(agen.prototype) === AsyncGeneratorPrototype,
  P(IteratorPrototype) === Object.prototype, P(AsyncIteratorPrototype) === Object.prototype,
  P(gen()) === gen.prototype, P(agen()) === agen.prototype, gen.prototype !== GeneratorPrototype);
print("no own constructor on instances' protos:", Object.getOwnPropertyDescriptor(gen.prototype, "constructor"),
  Object.getOwnPropertyDescriptor(agen.prototype, "constructor"), "prototype" in afn, afn.prototype);

const ag = agen();
print("asyncIterator:", typeof Symbol.asyncIterator, Symbol.asyncIterator.toString(), ag[Symbol.asyncIterator]() === ag,
  typeof AsyncIteratorPrototype[Symbol.asyncIterator], Symbol.asyncIterator === Symbol.asyncIterator);
print("methods:", typeof AsyncGeneratorPrototype.next, typeof AsyncGeneratorPrototype.return, typeof AsyncGeneratorPrototype.throw,
  AsyncGeneratorPrototype.next.length, AsyncGeneratorPrototype.next.name, ag.next() instanceof Promise);
print("toString tags:", Object.prototype.toString.call(gen()), Object.prototype.toString.call(ag));
print("functions inherit call/bind:", typeof agen.call, gen.bind(null).name, afn.apply(null, []) instanceof Promise);

// Function.prototype methods reached through the new prototypes; own props stay per function
gen.extra = 1;
print("own props:", gen.extra, agen.extra, "next" in GeneratorPrototype, "next" in AsyncGeneratorPrototype);
print("not constructable:", (() => { try { new agen(); return "constructed"; } catch (e) { return e instanceof TypeError; } })(),
  (() => { try { new afn(); return "constructed"; } catch (e) { return e instanceof TypeError; } })());
