// Flags and masks
const READ = 1 << 0;
const WRITE = 1 << 1;
const EXEC = 1 << 2;
let perms = READ | WRITE;
print(perms, (perms & WRITE) !== 0, (perms & EXEC) !== 0);
perms ^= EXEC;
print(perms);
perms &= ~WRITE;
print(perms);

// Hashing loop (32-bit wraparound)
let h = 2166136261;
const chars = [97, 98, 99, 100, 101];
for (let i = 0; i < chars.length; i++) {
  h ^= chars[i];
  h = (h + (h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24)) | 0;
}
print(h, h >>> 0);

// Negative numbers and unsigned right shift
print(~0, ~-1, ~2147483647, ~-2147483648);
print(-1 >> 1, -1 >>> 0, -1 >>> 1, -8 >> 2, -2147483648 >> 1, -2147483648 >>> 1);

// Shift count masking (& 31) and wraparound
print(1 << 31, 1 << 32, 1 << 33, 1 << -1, 1 >> -1, 1 >>> -1);
print(0x80000000 | 0, 4294967296 | 0, -4294967296 | 0, 4294967295.9 | 0, -4294967295.9 | 0);
print(1e21 | 0, -1e21 | 0, NaN | 0, Infinity | 0, -Infinity | 0, -0 | 0, 1e308 | 0);
print(1 << 32.9, 1 << NaN, 1 << Infinity, 1 << -0);

// Non-number operands (ToNumber)
print('5' & '3', '0xff' >> 4, 'abc' | 0, '0b1010' ^ '0b1100');
print(true << 2, false | true, null ^ 7, undefined & 7);
print(~null, ~undefined, ~'10', ~true, ~false);

// Precedence
print(1 | 2 & 3, 1 ^ 2 | 4, 3 & 1 === 1, 1 << 2 + 3, (~2) ** 2, 2 ** ~-2);

// Compound assignments on locals, closures, objects, and arrays
let local = 0b1010;
local &= 0b1100;
local |= 0b0011;
local ^= 0b0101;
local <<= 2;
local >>= 1;
print(local);
local = -1;
local >>>= 4;
print(local);

function makeMask(init) {
  let mask = init;
  return {
    add(b) { mask |= b; return mask; },
    clear(b) { mask &= ~b; return mask; },
    toggle(b) { mask ^= b; return mask; },
  };
}
const m = makeMask(1);
print(m.add(4), m.toggle(5), m.clear(0));

const obj = { flags: 0, mask: 0xff };
obj.flags |= 6;
obj['mask'] &= ~0x0f;
print(obj.flags, obj.mask);

const arr = [-1, 3, 12];
let idx = 0;
arr[idx++] >>>= 24;
arr[idx++] <<= 3;
arr[idx] >>= 1;
print(arr[0], arr[1], arr[2]);

// const and TDZ errors
try {
  const c = 1;
  c |= 2;
} catch (e) {
  print(e.name);
}
try {
  tdz &= 1;
  let tdz = 1;
} catch (e) {
  print(e.name);
}
