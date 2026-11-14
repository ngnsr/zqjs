// TDZ and const: where the checks sit relative to the right-hand side.
x = print('rhs first');     // set_local after the call: TDZ checked on the write
x += print('never');        // get_local first: TDZ checked on the read
let x = 1;
const c = 2;
c = print('rhs first');     // assign_const after the call
c += print('rhs, then op'); // get_local, call, add, then assign_const
c++;
