// Captured bindings live in cells: fresh per block execution (new_cell), parameters
// boxed on entry (box_local), reached from inner functions through captures (^N),
// including a capture of a capture; per-iteration copies (fresh_cell); a named
// expression's own name (push_callee).
let a;
{ let x = 1; a = function() { return x; }; }
function outer(p) {
  let depth = 0;
  function middle() { return function inner() { depth++; return p + depth + inner; }; }
  return middle;
}
for (let i = 0; i < 2; i++) { a = function() { return i; }; }
