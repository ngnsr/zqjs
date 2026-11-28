// Static methods of native constructors (Array.isArray, Object.keys, ...) are cached; an
// override, delete or redefinition must still be seen, and name/length stay virtual.
const out = [];
function hot(f) { let r; for (let i = 0; i < 50; i++) r = f(); return r; }
out.push("isArray", hot(() => Array.isArray([1])), hot(() => Array.isArray(1)));
const orig = Array.isArray;
Array.isArray = () => "patched";
out.push("patched", hot(() => Array.isArray([])));
Array.isArray = orig;
out.push("restored", hot(() => Array.isArray([])));
out.push("keys", hot(() => Object.keys({ a: 1, b: 2 }).join()), hot(() => Number.isInteger(3)), hot(() => String.fromCharCode(65)));
out.push("name/length", hot(() => Array.name), hot(() => Array.length), hot(() => Object.keys.length));
out.push("fn-proto", hot(() => typeof Array.call), hot(() => typeof Object.bind));
Object.defineProperty(Array, "from", { get() { return () => "getter"; }, configurable: true });
out.push("accessor", hot(() => Array.from([1])));
Array.myStatic = 7;
out.push("user-static", hot(() => Array.myStatic));
delete Array.myStatic;
out.push("user-static-deleted", hot(() => typeof Array.myStatic));
print(out.join("\n"));
