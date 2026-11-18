// Labels, comma operator, and tagged templates (both engines).

// 1. Labels: break/continue across blocks, loops, switch, and try..finally
let log = [];
outer: {
    log.push("a");
    if (true) break outer;
    log.push("unreachable");
}
log.push("b");

outerLoop: for (let i = 0; i < 3; i++) {
    for (let j = 0; j < 3; j++) {
        if (i === 1 && j === 1) continue outerLoop;
        if (i === 2 && j === 1) break outerLoop;
        log.push(i + ":" + j);
    }
}

a: b: while (true) {
    try {
        log.push("try");
        break a;
    } finally {
        log.push("finally");
    }
}
print(log.join(","));

// 2. Comma operator
let c1 = (1, 2, 3);
let c2;
c2 = 10, 20;
let sum = 0;
for (let i = 0, j = 4; i < 3; i++, j--) {
    sum += i + j;
}
print(c1, c2, sum, (true ? (1, 2) : 3));

// 3. Tagged templates: cooked, raw, invalid escapes, caching, and method `this`
function tag(strings, ...vals) {
    return strings.join("|") + "::" + strings.raw.join("|") + "::" + vals.join(",");
}
print(tag`a\nb${1 + 2}c\\d`);
print(tag`\unicode${42}`);

const seen = [];
function capture(s) {
    seen.push(s);
    return s;
}
for (let k = 0; k < 2; k++) capture`hello`;
print(seen[0] === seen[1], seen[0].raw === seen[1].raw, seen[0][0], seen[0].raw[0]);

const obj = {
    prefix: "P:",
    fmt(s, v) {
        return this.prefix + s[0] + v;
    },
};
print(obj.fmt`val=${99}`);
