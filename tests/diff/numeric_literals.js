// M21.1: hex, octal and binary integers and numeric separators.
print(0x0, 0x1F, 0XaB, 0xffffffff, 0o0, 0o17, 0O777, 0b0, 0b101, 0B11111111);
print(1_000_000, 1_000.000_5, .5_5, 1e1_0, 1_0e-2, 0.000_001, 0xff_ff, 0b1010_1010, 0o7_7);
// past 2^53: correctly rounded, ties to even
print(0x1fffffffffffff, 0x20000000000001, 0x20000000000003, 0x200000000000011);
print(0xffffffffffffffffffffffffffffffff, 0b1111111111111111111111111111111111111111111111111111111);
print(-0x10, -0b1, 0x10 + 0o10 + 0b10, 0x10 === 16, 1_000 === 1000, typeof 0xff);
const o = { 0x10: "hex", 0b11: "bin", 1_0: "sep" };
print(Object.keys(o).join(","), o[16], o[3], o[10]);
let big = 0x1_0000_0000;
print(big, `${0o1_0}`, [0b1, 0o2, 0x3].map(x => x * 2).join("|"));
