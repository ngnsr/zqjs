// for (let …) gives each iteration its own binding (CreatePerIterationEnvironment).
let f0, f1, f2;
for (let i = 0; i < 3; i++) {
  if (i === 0) f0 = function() { return i; };
  if (i === 1) f1 = function() { return i; };
  if (i === 2) f2 = function() { return i; };
}
print(f0(), f1(), f2());
// The body changes i: the change is visible to that iteration's closure and carried on.
let g0, g1;
for (let i = 0; i < 6; i++) {
  if (i === 0) { g0 = function() { return i; }; i = 2; }
  if (i === 3) g1 = function() { return i; };
}
print(g0(), g1());
// The update runs on the *new* iteration's binding: earlier closures don't see it.
let h0;
for (let i = 0; i < 3; i = i + 1) { if (i === 0) h0 = function() { i = i + 100; return i; }; }
print(h0(), h0());
// continue still copies and updates.
let kept = 'none';
for (let i = 0; i < 4; i++) { if (i < 3) continue; kept = function() { return i; }; }
print(kept());
// A closure created in the initialiser sees the first binding, not later copies.
let init;
// A closure over a `const` head binding, and a while loop (no per-iteration copies).
let c;
for (const z = 'const head'; !c; ) c = function() { return z; };
print(c());
