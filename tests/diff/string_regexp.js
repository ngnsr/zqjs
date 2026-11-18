// M30: String.prototype.{match, search, replace, replaceAll, split} with RegExp.

// 1. String.prototype.match
const s = "cat bat rat";
const mSingle = s.match(/([cbr])at/);
print(mSingle[0], mSingle[1], mSingle.index, mSingle.input);
print(s.match(/dog/));

const rAll = /([cbr])at/g;
rAll.lastIndex = 99;
const mAll = s.match(rAll);
print(mAll.length, mAll.join(","), rAll.lastIndex);
print(s.match(/dog/g), rAll.lastIndex);

// Empty matches with match(/.../g) advance by 1
print("ab".match(/a*/g).join("|"));
print("ab".match(/(?:)/g).length);

// Non-RegExp coercion in match
print("hello".match("ll")[0], "hello".match("ll").index);
print("hello".match()[0], "hello".match().index);

// 2. String.prototype.search
const rSearch = /bat/g;
rSearch.lastIndex = 50;
print(s.search(rSearch), rSearch.lastIndex);
print(s.search(/dog/), s.search("rat"), s.search());
print("abc".search(/b/y), "abc".search(/a/y));

// 3. String.prototype.replace with string patterns ($&, $`, $', $$, $1..$9, $nn)
print("foo bar".replace(/(\w+)\s+(\w+)/, "$2, $1 ($&) [$`|$'] $$"));
print("ab".replace(/(a)(b)/, "$1-$2-$3-$10-$01-$0-$&"));
print("ac".replace(/(a)(b)?(c)/, "$1|$2|$3"));
print("aaa".replace(/a/, "x"), "aaa".replace(/a/g, "x"));
print("ab".replace(/a*/g, "-"));
print("ab".replace(/(?:)/g, "|"));

// 4. String.prototype.replace with callback function
const cbLog = [];
const replaced = "a1 b22 c333".replace(/([a-z])(\d+)/g, (match, p1, p2, offset, str) => {
    cbLog.push(`${match}:${p1}:${p2}@${offset}/${str.length}`);
    return p1.toUpperCase() + "#" + p2.length;
});
print(replaced);
print(cbLog.join(" | "));

// Callback with unmatched capture group and callback mutating lastIndex
const rMut = /(a)(b)?/g;
const mutOut = "aba".replace(rMut, (m, p1, p2, off) => {
    rMut.lastIndex = 999;
    return `${p1}${p2 === undefined ? "_" : p2}@${off}`;
});
print(mutOut);

// 5. String.prototype.replaceAll with RegExp
print("a1 a2 a3".replaceAll(/a(\d)/g, "#$1"));
print("a1 a2".replaceAll(/a(\d)/g, (m, d, off) => `${d}@${off}`));
try {
    "a1 a2".replaceAll(/a\d/, "x");
    print("FAIL");
} catch (e) {
    print("replaceAll non-g:", e instanceof TypeError, e.name);
}

// 6. String.prototype.split with RegExp
print("a, b ,  c,d".split(/\s*,\s*/).join("|"));
print("a1b2c3".split(/(\d)/).join("|"));
print("a1b2c3".split(/(\d)/, 3).join("|"));
print("a1b2c3".split(/(\d)/, 0).length);
const splitUnmatched = "ab".split(/(a)(x)?/);
print(splitUnmatched.length, splitUnmatched[0], splitUnmatched[1], splitUnmatched[2], splitUnmatched[3]);
print("".split(/a*/).length, "".split(/a+/).length, "".split(/a+/)[0]);
print("ab".split(/a*/).join("|"));
print("ab".split(/(a)?/).join("|"));
print("ab".split(/()/).join("|"));
print("ab".split(/(?:)/).join("|"));
const rSplitY = /b/y;
rSplitY.lastIndex = 9;
print("aba".split(rSplitY).join("|"), rSplitY.lastIndex);
