// M30: RegExp literals, constructor, properties, instanceof, exec, and test.

// 1. Literals create fresh instances per evaluation with canonical flags
const seen = [];
for (let i = 0; i < 3; i++) {
    const r = /a+/yimsg;
    r.lastIndex = i + 1;
    seen.push(r);
}
print(seen[0] !== seen[1], seen[1] !== seen[2]);
print(seen[0].lastIndex, seen[1].lastIndex, seen[2].lastIndex);
print(seen[0].source, seen[0].flags, seen[0].toString());
print(seen[0].global, seen[0].ignoreCase, seen[0].multiline, seen[0].dotAll, seen[0].sticky);

// Special literal forms: /=.../, [/], escaped slash
const rEq = /=(\d+)/;
print(rEq.source, rEq.test("x=42"), rEq.exec("x=42")[1]);
const rClassSlash = /[/]+/;
print(rClassSlash.source, rClassSlash.toString(), rClassSlash.exec("a//b")[0]);
const rEscSlash = /a\/b/;
print(rEscSlash.source, rEscSlash.toString(), rEscSlash.test("a/b"));

// 2. RegExp constructor vs function call
const rEmpty1 = new RegExp();
const rEmpty2 = RegExp(undefined, "m");
print(rEmpty1.source, rEmpty1.flags, rEmpty1.toString());
print(rEmpty2.source, rEmpty2.flags, rEmpty2.toString(), rEmpty2.multiline);

const rSlash = new RegExp("a/b[/]c\nd", "gi");
print(rSlash.source, rSlash.flags, rSlash.toString());

const orig = /foo/gi;
orig.lastIndex = 7;
const same = RegExp(orig);
print(same === orig, same.lastIndex);
const cloned = new RegExp(orig);
print(cloned !== orig, cloned.source, cloned.flags, cloned.lastIndex);
const reflagged = new RegExp(orig, "my");
print(reflagged !== orig, reflagged.source, reflagged.flags, reflagged.global, reflagged.multiline, reflagged.sticky);
const reflaggedCall = RegExp(orig, "i");
print(reflaggedCall !== orig, reflaggedCall.source, reflaggedCall.flags);

// Runtime SyntaxErrors on invalid pattern or flags
for (const bad of [
    () => new RegExp("(", ""),
    () => new RegExp("[a", ""),
    () => new RegExp("a", "gg"),
    () => new RegExp("a", "z"),
    () => new RegExp("a", "uv"),
    () => RegExp("*", "i"),
]) {
    try {
        bad();
        print("FAIL");
    } catch (e) {
        print("caught:", e instanceof SyntaxError, e instanceof Error, e.name);
    }
}

// 3. Object model, properties, instanceof, conversions
const rx = /hello/gi;
print(rx instanceof RegExp, rx instanceof Object, rx instanceof Array);
print(Object.getPrototypeOf(rx) === RegExp.prototype);
print(rx.constructor === RegExp);
print(Object.keys(rx).length);
print("lastIndex" in rx, "source" in rx, "flags" in rx, "global" in rx, "exec" in rx, "test" in rx);
print(delete rx.lastIndex, delete rx.source);
rx.source = "changed";
rx.global = false;
print(rx.source, rx.global);
rx.tag = "custom";
print(rx.tag, Object.keys(rx).join(","));
print(delete rx.tag, rx.tag, Object.keys(rx).length);
print(String(rx), "" + rx, `${rx}`);

// 4. exec and test: non-global, global (g), sticky (y)
const rPlain = /(\w+)-(\d+)?/;
rPlain.lastIndex = 99;
const m1 = rPlain.exec("...abc-123...");
print(Array.isArray(m1), m1.length, m1[0], m1[1], m1[2], m1.index, m1.input, rPlain.lastIndex);
const m2 = rPlain.exec("...abc-...");
print(m2[0], m2[1], m2[2], m2.index);
print(rPlain.exec("..."), rPlain.lastIndex);

const rGlobal = /(\w)(\d)/g;
const sGlobal = "a1 b2 c3";
const found = [];
while (true) {
    const m = rGlobal.exec(sGlobal);
    if (m === null) {
        found.push("null@" + rGlobal.lastIndex);
        break;
    }
    found.push(m[0] + ":" + m[1] + ":" + m[2] + "@" + m.index + "->" + rGlobal.lastIndex);
}
print(found.join(" | "));

// Out-of-bounds and string-coerced lastIndex on g/y
rGlobal.lastIndex = 100;
print(rGlobal.exec(sGlobal), rGlobal.lastIndex);
rGlobal.lastIndex = "3";
const mFrom3 = rGlobal.exec(sGlobal);
print(mFrom3[0], mFrom3.index, rGlobal.lastIndex);
rGlobal.lastIndex = -5;
const mNeg = rGlobal.exec(sGlobal);
print(mNeg[0], mNeg.index, rGlobal.lastIndex);

// Sticky (y)
const rSticky = /\w+/y;
const sSticky = "foo_bar baz";
print(rSticky.test(sSticky), rSticky.lastIndex);
print(rSticky.test(sSticky), rSticky.lastIndex);
rSticky.lastIndex = 1;
const mSticky = rSticky.exec(sSticky);
print(mSticky[0], mSticky.index, rSticky.lastIndex);

// 5. Engine features through runtime: backrefs, lookahead, multiline, dotAll, quantifiers
print(/(a|b)\1/i.exec("xBbY")[0]);
print(/\d+(?=px)/g.exec("10em 25px")[0]);
print(/\d+(?!px)/.exec("10px 25em")[0]);
print(/^b$/m.test("a\nb\nc"), /^b$/.test("a\nb\nc"));
print(/a.b/s.test("a\nb"), /a.b/.test("a\nb"));
print(/a{2,4}?/.exec("aaaaa")[0], /a{2,4}/.exec("aaaaa")[0]);
