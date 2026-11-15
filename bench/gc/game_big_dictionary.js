// Game-like GC workload (M8.1 P2): 200k long-lived entities in one object used as a
// dictionary (keyed by name), and every frame one entry is replaced by a new object: a
// young value stored into a huge old property table. Arrays have cards; property tables
// don't, so this measures what a remembered dictionary costs a minor collection.
let byName = {};
for (let i = 0; i < 200000; i++) byName['e' + i] = { id: i, x: i % 640, y: i % 480 };
let checksum = 0;
for (let frame = 0; frame < 300; frame++) {
  let slot = (frame * 7919) % 200000;
  byName['e' + slot] = { id: slot, x: frame, y: frame };
  for (let k = 0; k < 2000; k++) {
    let e = byName['e' + ((frame * 2000 + k) % 200000)];
    let v = { dx: (k % 3) - 1, dy: (k % 5) - 2 };
    let label = 'f' + frame + ':' + e.id;
    e.x = e.x + v.dx; e.y = e.y + v.dy;
    checksum = checksum + label.length;
  }
}
print(checksum, byName['e7919'].x, byName['e123456'].y);
