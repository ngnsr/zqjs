// String.prototype.charCodeAt: in-range integer indices take a VM fast path; every other
// index form must still follow the spec, and an overridden method must be called.
const s = "h\u00e9llo\ud83d\ude00";
print(s.charCodeAt(0), s.charCodeAt(1), s.charCodeAt(5), s.charCodeAt(6));
print(s.charCodeAt(1.9), s.charCodeAt(-0), s.charCodeAt(NaN), s.charCodeAt("2"));
print(s.charCodeAt(-1), s.charCodeAt(7), s.charCodeAt(Infinity), s.charCodeAt());
let h = 2166136261;
for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619) >>> 0; }
print("fnv", h);
const orig = String.prototype.charCodeAt;
String.prototype.charCodeAt = function (i) { return 1000 + i; };
print("override", "abc".charCodeAt(2));
String.prototype.charCodeAt = orig;
print("restored", "abc".charCodeAt(2));
