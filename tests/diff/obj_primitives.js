// Strings: length and indexing count UTF-16 code units, including lone surrogates.
let s = 'a😀b';
print(s.length, s[0], s.charCodeAt(1), s.charCodeAt(2), s.charCodeAt(9), s[9], s['1'] === '\uD83D');
print('abc'.charCodeAt(), 'abc'.charCodeAt(1.7), 'abc'.charCodeAt('2'), ''.length);
// Property reads on primitives go to their prototype; unknown names are undefined.
print((1).foo, true.bar, 'x'.baz, Object.keys('hi'), Object.keys(5));
// Methods called on primitives.
let t = 'xyz';
print(t.charCodeAt(0) + t.charCodeAt(2));
