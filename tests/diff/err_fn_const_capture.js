// Assigning to a captured const: the right-hand side runs first, then TypeError.
const k = 1;
function set() { k = print('rhs first'); }
set();
