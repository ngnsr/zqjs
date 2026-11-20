// String.prototype.matchAll, fromCharCode, fromCodePoint, codePointAt, URI functions (M44, D74).

// matchAll
const re = /t(e)(st(\d?))/g;
re.lastIndex = 1;
const matches = [..."test1test2".matchAll(re)];
print(matches.length, re.lastIndex);
for (const m of matches) {
  print(m[0], m[1], m[2], m.index);
}

// Zero-length matches & unicode surrogate pair advancement
const uMatches = [..."a😀b".matchAll(/(?:)/gu)];
print(uMatches.map((m) => m.index).join(","));

// String argument to matchAll
print([..."ababa".matchAll("a")].map((m) => m.index).join(","));

// Non-global RegExp throws TypeError
try {
  "abc".matchAll(/a/);
} catch (e) {
  print(e.name);
}

// fromCharCode, fromCodePoint, codePointAt
print(String.fromCharCode(65, 66, 0x10043));
print(String.fromCodePoint(65, 0x1F600, 66));
try {
  String.fromCodePoint(0x110000);
} catch (e) {
  print(e.name);
}
try {
  String.fromCodePoint(-1);
} catch (e) {
  print(e.name);
}
try {
  String.fromCodePoint(1.5);
} catch (e) {
  print(e.name);
}
const s = "A😀B";
print(s.codePointAt(0), s.codePointAt(1), s.codePointAt(2), s.codePointAt(3), s.codePointAt(4));

// URI functions
const sample = "https://example.com/a b?q=hello world&x=1+2#sec😀";
const enc1 = encodeURI(sample);
print(enc1);
print(decodeURI(enc1) === sample);
print(decodeURI("%2F%3F%23%20"));

const enc2 = encodeURIComponent(sample);
print(enc2);
print(decodeURIComponent(enc2) === sample);

// URIError cases
for (const fn of [
  () => encodeURI("\uD800"),
  () => encodeURIComponent("\uDC00"),
  () => decodeURI("%E0%A4%A"),
  () => decodeURIComponent("%ZZ"),
  () => decodeURIComponent("%C0%AF"),
  () => decodeURIComponent("%ED%A0%80"),
]) {
  try {
    fn();
  } catch (e) {
    print(e.name);
  }
}
