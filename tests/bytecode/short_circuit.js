// && and || keep the deciding operand: dup, conditional jump, pop, rhs.
let a = '' || 'd';
let b = a && null;
print(a, b, !a, -a);
