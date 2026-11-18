// 1. d flag (hasIndices) & canonical flag order
const rd = /(?<word>\w+)/dgimsuy;
print(rd.hasIndices, rd.unicode, rd.unicodeSets, rd.flags);
const md = rd.exec("hello world");
print(md[0], md.index, md.indices[0][0], md.indices[0][1]);
print(md.indices[1][0], md.indices[1][1]);
print(md.indices.groups.word[0], md.indices.groups.word[1]);
print(Object.getPrototypeOf(md.groups) === null, Object.getPrototypeOf(md.indices.groups) === null);

const rdOpt = /(?:(a)|(?<bgrp>b))/d.exec("b");
print(rdOpt.indices[1], rdOpt.indices[2][0], rdOpt.indices[2][1], rdOpt.indices.groups.bgrp[0], rdOpt.indices.groups.bgrp[1]);

// 2. u flag: surrogate pairs, \u{...}, \p{...}, /iu
const ru = /\u{1F600}.(?<grk>\p{Script=Greek})/u;
print(ru.unicode, ru.flags);
const mu = ru.exec("😀xΩ");
print(mu[0], mu.groups.grk);
print(/^.$/u.test("😀"), /^.$/.test("😀"));
print(/\P{ASCII}/u.test("é"), /\P{ASCII}/u.test("a"));

// 3. Non-ASCII /i (legacy vs u)
print(/é/i.test("É"), /\u00e9/i.test("\u00c9"));
print(/k/i.test("\u212a"), /k/iu.test("\u212a"));
print(/\u{10400}/iu.test("\u{10428}"));

// 4. v flag (unicodeSets)
const rv1 = /^[[a-z]--[aeiou]]+$/v;
print(rv1.unicodeSets, rv1.unicode, rv1.flags);
print(rv1.test("bcdfg"), rv1.test("abc"));
print(/^[\p{ASCII}&&\p{Letter}]+$/v.test("Hello"), /^[\p{ASCII}&&\p{Letter}]+$/v.test("Hello1"));
print(/^[\q{foo|bar}]+$/v.test("foobar"), /^[\q{foo|bar}]+$/v.test("foobaz"));
print(/^\p{Basic_Emoji}$/v.test("⌚"));

// 5. Named groups + \k<name> + replace $<name> & callback groups arg
const rname = /(?<x>[a-z]+)-\k<x>/;
print(rname.test("ab-ab"), rname.test("ab-cd"));
print("a1-b2".replace(/(?<k>[a-z])(?<v>\d)/g, "$<v>:$<k>"));
print("a1".replace(/(?<k>[a-z])(?<v>\d)/, (m, p1, p2, off, str, groups) => groups.v + "=" + groups.k));

// 6. Lookbehind
print(/(?<=\$)\d+/.exec("$42")[0]);
print(/(?<!\$)\d+/.exec("$42 99")[0]);
print(/(?<=(a+))b/.exec("aaab")[1]);

// 7. Inline modifiers
print(/(?i:abc)def/.test("ABCdef"), /(?i:abc)def/.test("ABCDEF"));
print(/(?-i:abc)/i.test("abc"), /(?-i:abc)/i.test("ABC"));
print(/(?m:^b)/s.test("a\nb"));
print(/(?s:.)/.test("\n"), /(?-s:.)/s.test("\n"));

// 8. \cA and \10+ backreferences
print(/\cA/.test("\x01"), /[\cZ]/.test("\x1a"));
print(/(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)\10\1/.test("abcdefghijja"));
