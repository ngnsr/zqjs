// For `=`, the key is converted after the right-hand side: rhs prints, then TypeError.
let o = {};
o[Object.create(null)] = print('rhs first');
