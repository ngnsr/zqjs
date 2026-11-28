// Property reads on built-in objects (Math, JSON, prototypes) and on Map/Set/Date/etc.
// instances are cached; overriding, deleting, shadowing or redefining must still be seen.
const out = [];
function hot(f) { let r; for (let i = 0; i < 50; i++) r = f(); return r; }
out.push("imul", hot(() => Math.imul(3, 5)));
const origImul = Math.imul;
Math.imul = function () { return -1; };
out.push("imul-overridden", hot(() => Math.imul(3, 5)));
Math.imul = origImul;
out.push("imul-restored", hot(() => Math.imul(3, 5)));
const m = new Map([[1, "a"]]);
out.push("map-get", hot(() => m.get(1)));
const origGet = Map.prototype.get;
Map.prototype.get = function () { return "patched"; };
out.push("map-proto-patched", hot(() => m.get(1)));
Map.prototype.get = origGet;
out.push("map-proto-restored", hot(() => m.get(1)));
m.get = () => "own";
out.push("map-own-shadow", hot(() => m.get(1)));
delete m.get;
out.push("map-own-deleted", hot(() => m.get(1)));
const s = new Set([1]);
out.push("set-has", hot(() => s.has(1)), hot(() => s.size));
const d = new Date(0);
out.push("date-getTime", hot(() => d.getTime()));
out.push("json", hot(() => JSON.stringify([1])));
out.push("math-pi", hot(() => Math.PI), hot(() => typeof Math.toString));
const w = new WeakMap(); const k = {};
w.set(k, 7); out.push("weakmap", hot(() => w.get(k)));
const p = Promise.resolve(1); out.push("promise-then", hot(() => typeof p.then));
Object.defineProperty(Math, "imul", { get() { return () => 99; }, configurable: true });
out.push("imul-accessor", hot(() => Math.imul(1, 1)));
print(out.join("\n"));
