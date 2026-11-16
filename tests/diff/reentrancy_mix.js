// Interleaved Array.map -> Map.forEach -> Set.forEach -> Array.filter -> Array.reduce -> JSON
const data = [
  '{"k":"a","vals":[1,2,3]}',
  '{"k":"b","vals":[4,5]}',
];

const summary = data.map(function (raw) {
  const parsed = JSON.parse(raw);
  const m = new Map([[parsed.k, parsed.vals]]);
  let total = 0;
  m.forEach(function (arr, key) {
    const s = new Set(arr);
    const evens = [];
    s.forEach(function (n) {
      if (n % 2 === 0) evens.push(n);
    });
    const kept = arr.filter(function (n) { return n > 1; });
    total += kept.reduce(function (a, b) { return a + b; }, 0) + evens.length;
    if (key === "a") m.set("extra", [10]);
  });
  return JSON.stringify({ key: parsed.k, total: total });
});
print(summary.join("|"));

// Exception unwinding across 3 nested callback built-ins
try {
  [1, 2].map(function (x) {
    new Map([["m", x]]).forEach(function (v) {
      new Set([v]).forEach(function (s) {
        if (s === 2) throw "deep-boom";
      });
    });
    return x;
  });
} catch (e) {
  print("caught", e);
}

// Runtime remains healthy for further callback + JSON work
print([10, 20].reduce(function (a, b) { return a + b; }, 0));
