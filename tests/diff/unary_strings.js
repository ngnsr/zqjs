// Unary operators on strings (a VM result-location aliasing bug, DESIGN_DECISIONS D35).
let s = '3', e = '', w = ' 0x1f ';
print(-s, +s, !s, -e, +e, !e, +w, -w, +'abc', !'0', -'-0');
