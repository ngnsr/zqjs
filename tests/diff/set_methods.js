// Set.prototype ES2025 set-theory methods (M44, D74).

const a = new Set([1, 2, 3]);
const b = new Set([2, 3, 4]);
const c = new Set([4, 5]);
const sub = new Set([1, 3]);

print(JSON.stringify([...a.union(b)]));
print(JSON.stringify([...a.intersection(b)]));
print(JSON.stringify([...a.difference(b)]));
print(JSON.stringify([...a.symmetricDifference(b)]));
print(sub.isSubsetOf(a), a.isSubsetOf(sub));
print(a.isSupersetOf(sub), sub.isSupersetOf(a));
print(a.isDisjointFrom(c), a.isDisjointFrom(b));

// Custom Set-like object
const setLike = {
  size: 2,
  has(v) { return v === 2 || v === 5; },
  keys() {
    let i = 0;
    const vals = [2, 5, 2];
    return {
      next() {
        return i < vals.length ? { value: vals[i++], done: false } : { done: true };
      }
    };
  }
};

print(JSON.stringify([...a.union(setLike)]));
print(JSON.stringify([...a.intersection(setLike)]));
print(JSON.stringify([...a.difference(setLike)]));
print(JSON.stringify([...a.symmetricDifference(setLike)]));
print(new Set([2, 5]).isSubsetOf(setLike));
print(new Set([1, 2, 5]).isSupersetOf(setLike));
print(new Set([1, 3]).isDisjointFrom(setLike));

// Validation errors
for (const bad of [
  { size: -1, has() { return false; }, keys() { return { next() { return { done: true }; } }; } },
  { size: NaN, has() { return false; }, keys() { return { next() { return { done: true }; } }; } },
  { size: 1, has: 123, keys() { return { next() { return { done: true }; } }; } },
  { size: 1, has() { return false; }, keys: "nope" },
]) {
  try {
    a.union(bad);
  } catch (e) {
    print(e.name);
  }
}
