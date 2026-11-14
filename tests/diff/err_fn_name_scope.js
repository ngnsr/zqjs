// A named function expression's name is not visible outside it.
const e = function inner() { return 1; };
print(e());
inner;
