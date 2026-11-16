let a = [1, 2, 3];
print(a.push(4, 5), a.join("-"));
print(a.pop(), a.pop(), a.length, [].pop());

let s = [10, 20, 30, 40, 50];
let copy = s.slice();
copy[0] = 99;
print(s.join(","), copy.join(","));
print(s.slice(1, 4).join(","), s.slice(2).join(","), s.slice(-2).join(","), s.slice(-4, -1).join(","));
print(s.slice(4, 2).length, s.slice(-100, 2).join(","), s.slice(undefined, -3).join(","), s.slice(1, undefined).join(","));
print(s.slice(NaN, Infinity).join(","), s.slice(-Infinity, 1).join(","));

let d = [1, 2, NaN, 2, -0, "2"];
print(d.indexOf(2), d.indexOf(2, 2), d.indexOf(2, -2), d.indexOf(2, -100), d.indexOf(2, 100));
print(d.indexOf(NaN), d.indexOf(0), d.indexOf("2"), [].indexOf(1));

print(d.includes(2), d.includes(NaN), d.includes(0), d.includes(2, 4), d.includes(2, -3), d.includes("2", -1));
print(d.includes(1, -100), d.includes(1, Infinity), [].includes(undefined));

let j = [1, null, undefined, true, [2, 3]];
print(j.join(), j.join(""), j.join("|"), j.join(0), j.join(null), [].join(","));
