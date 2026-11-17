// Runs at least once even when condition is false
let runs = 0;
do {
  runs++;
} while (false);
print('runs:', runs);

// Basic loop
let i = 0;
let sum = 0;
do {
  sum += i;
  i++;
} while (i < 5);
print('sum:', sum, 'i:', i);

// break and continue (continue jumps to condition)
let c = 0;
const out = [];
do {
  c++;
  if (c === 2) continue;
  out.push(c);
  if (c === 4) break;
} while (c < 10);
print('out:', out.join(','), 'c:', c);

// continue still evaluates condition and exits if false
let once = 0;
do {
  once++;
  continue;
} while (once < 1);
print('once:', once);

// Per-iteration let bindings captured by closures
const fns = [];
let k = 0;
do {
  let v = k * 10;
  fns.push(() => v);
  k++;
} while (k < 4);
print(fns.map(f => f()).join(','));

// Return from inside do-while in a function
function findFirst(limit) {
  let n = 0;
  do {
    if (n === limit) return n * 100;
    n++;
  } while (n < 5);
  return -1;
}
print(findFirst(3), findFirst(10));
