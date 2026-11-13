print(true && 'yes', 0 && 'no', '' || 'default', 'set' || 'unused', null || undefined, 1 && 2 && 3, 0 || '' || null);
print(!0, !1, !'', !'x', !null, !undefined, !NaN, !!'0', !!-0);
false && print('not printed');
true || print('not printed');
let n = 0;
(n = 1) && (n = 2);
print(n);
