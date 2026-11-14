// Calling a closure before the binding it captures is initialised: TDZ.
function read() { return x; }
print('before');
read();
let x = 1;
