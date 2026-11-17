// Plain and empty
print(``);
print(`hello`);

// Numbers, booleans, null, undefined
print(`${-0} ${NaN} ${Infinity} ${-Infinity} ${1e21} ${0.1 + 0.2}`);
print(`${null} ${undefined} ${true} ${false}`);

// Arrays and plain objects
print(`${[]} ${[1, 2, null, undefined, 3]} ${[[1, 2], [3]]}`);
print(`${{}}`);

// Nested templates
const x = 10;
print(`outer(${`inner(${x + 1})`})`);
print(`${`${`${42}`}`}`);

// Escapes
print(`\b\f\n\r\t\v\0`);
print(`\x41\u0042\u{1F600}`);
print(`\` \$ \\ \${1}`);
print(`line\
continuation`);

// Multi-line raw newlines
print(`line1
line2
line3`);

// Evaluation order and ToString before next substitution
const log = [];
function step(name, val) {
  log.push(name);
  return val;
}
print(`${step('a', 1)}-${step('b', 2)}-${step('c', 3)}`);
print(log.join(','));
