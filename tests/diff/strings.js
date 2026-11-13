print('a' + 1 + 2, 1 + 2 + 'a', 'x' + null, 'x' + undefined, 'x' + true, '' + 1e21, 'n=' + -1.5);
let s = ''; for (let i = 0; i < 5; i++) { s += i; } print(s, s + s);
print('é' + '😀', '\uD83D' + '\uDE00', '\u{1F600}' === '\uD83D\uDE00', '\uD800', 'a\uDC00b');
print('it\'s', "say \"hi\"", 'tab\there', 'a\
b', '\x41\u0042\u{43}');
