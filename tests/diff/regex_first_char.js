// Regexes starting with a literal skip start positions that cannot match; the results,
// lastIndex updates and surrogate handling must be exactly as without the shortcut.
const s = "a*b **bold** x `code` [l](u) **two** end";
print(s.replace(/\*\*(.+?)\*\*/g, "<b>$1</b>"));
print(s.replace(/`([^`]+)`/g, "<c>$1</c>"), s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, "<a $2>$1</a>"));
const g = /\*/g; const hits = []; let m;
while ((m = g.exec(s)) !== null) hits.push(m.index + ":" + g.lastIndex);
print(hits.join(","));
const y = /b/y; y.lastIndex = 2; print(y.test("a*b"), y.lastIndex); y.lastIndex = 1; print(y.test("a*b"), y.lastIndex);
print("xxaxx".search(/a/), "xx".search(/a/), "".search(/a/), "a".search(/a/));
print(/z/.exec("abc"), /c/.exec("abc").index, "abcabc".match(/b/g).length);
const astral = "x😀a😀a";
print(astral.match(/a/gu).length, astral.replace(/a/gu, "A"), /\ud83d/.test(astral), /\ud83d/u.test(astral));
print("{{ name }} and {{x}}".replace(/\{\{\s*(\w+)\s*\}\}/g, (_, k) => "<" + k + ">"));
print("Aa".replace(/a/gi, "_"), "ab\nab".match(/^a/gm).length, "aaa".split(/a/).length);
