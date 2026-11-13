print('10' < '9', '10' < 9, 9 < '10', 'a' < 'b', 'B' < 'a', 'abc' < 'abd', 'ab' < 'abc', '' < 'a');
print(null < 1, undefined < 1, null >= 0, null <= 0, NaN < 1, NaN >= NaN, 1 <= 1, 2 >= 3);
print(1 === 1, 1 === '1', 'a' === 'a', null === undefined, NaN === NaN, NaN !== NaN, true === true, 'x' !== 'y');
print('\uD83D' < '\uDE00', '\uFFFF' < '\uD83D\uDE00', '\u{1F600}' < '\uFFFF');
