function show(v) {
  if (v === undefined) return 'undefined';
  if (v === null) return 'null';
  return JSON.stringify(v);
}

// split
print(show(''.split()));
print(show(''.split('')));
print(show(''.split(',')));
print(show('a,b,c'.split(',')));
print(show('a,b,'.split(',')));
print(show(',a,'.split(',')));
print(show('abc'.split('')));
print(show('a,b,c'.split(',', 0)));
print(show('a,b,c'.split(',', 2)));
print(show('a,b,c'.split(',', -1)));
print(show('a,b,c'.split(',', undefined)));
print(show('a,b,c'.split(undefined, 0)));
print(show('a,b,c'.split(undefined, 2)));
print(show('😀a😀'.split('')));
print(show('😀a😀'.split('😀')));

// trim, trimStart, trimEnd
let ws = ' \t\n\r\v\f\u00A0\u1680\u2000\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF';
let padded = ws + 'hi' + ws;
print(show(padded.trim()), show(padded.trimStart()), show(padded.trimEnd()));
print(show(ws.trim()), show(''.trim()));

// startsWith, endsWith
print('hello world'.startsWith('hello'), 'hello world'.startsWith('world', 6), 'hello world'.startsWith('world', 7));
print('hello world'.startsWith('', 100), 'hello'.startsWith('h', -5), 'hello'.startsWith('h', NaN));
print('hello world'.endsWith('world'), 'hello world'.endsWith('hello', 5), 'hello world'.endsWith('hello', 4));
print('hello world'.endsWith('', 0), 'hello'.endsWith('o', Infinity), 'hello'.endsWith('h', -1));

// repeat
print(show('ab'.repeat(0)), show('ab'.repeat(3)), show(''.repeat(1e20)), show('x'.repeat(NaN)));
for (let bad of [-1, -Infinity, Infinity]) {
  try {
    'a'.repeat(bad);
    print('no throw');
  } catch (e) {
    print(e.name);
  }
}

// padStart, padEnd
print(show('5'.padStart(3, '0')), show('5'.padStart(3)), show('5'.padStart(1, '0')));
print(show('abc'.padStart(6, '12345')), show('abc'.padStart(6, '')));
print(show('5'.padEnd(3, '0')), show('5'.padEnd(3)), show('5'.padEnd(1, '0')));
print(show('abc'.padEnd(6, '12345')), show('abc'.padEnd(6, '')));
print(show('a'.padStart(NaN, 'x')), show('a'.padEnd(-5, 'x')));

// substring
print(show('abcdef'.substring(1, 4)), show('abcdef'.substring(4, 1)));
print(show('abcdef'.substring(-3, 2)), show('abcdef'.substring(2, Infinity)));
print(show('abcdef'.substring(NaN, 3)), show('abcdef'.substring(3)));

// lastIndexOf
print('canal'.lastIndexOf('a'), 'canal'.lastIndexOf('a', 2), 'canal'.lastIndexOf('a', 0));
print('canal'.lastIndexOf('x'), 'canal'.lastIndexOf('', 2), 'canal'.lastIndexOf('', 100));
print('canal'.lastIndexOf('a', NaN), 'canal'.lastIndexOf('a', -5));

// at
print(show('abc'.at(0)), show('abc'.at(-1)), show('abc'.at(-4)), show('abc'.at(3)));
print(show('😀'.at(0)), show('😀'.at(1)), show('abc'.at(NaN)), show('abc'.at(Infinity)));

// replace & replaceAll
print(show('foo bar foo'.replace('foo', 'baz')));
print(show('foo bar foo'.replaceAll('foo', 'baz')));
print(show('foo'.replace('zzz', 'x')), show('foo'.replaceAll('zzz', 'x')));
print(show('ab'.replace('', '-')), show('ab'.replaceAll('', '-')), show(''.replaceAll('', '-')));
print(show('abc'.replace('b', '$$-$&-$-$`-$\'-$-')));
print(show('abc'.replace('b', '$1-$x-$')));
print(show('aabb'.replaceAll('b', '[$&:$`:$\':$$]')));

// function replacer
let calls = [];
let r1 = 'hello world'.replace('o', function (m, idx, str) {
  calls.push([m, idx, str]);
  return m + '!';
});
let r2 = 'ab'.replaceAll('', function (m, idx, str) {
  calls.push([m, idx, str]);
  return '|';
});
print(show(r1), show(r2), show(calls));
