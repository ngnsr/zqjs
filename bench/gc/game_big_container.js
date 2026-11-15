// Game-like GC workload (M8.1): 1M long-lived entities in one array, and every frame
// one of them is replaced by a new object: a young value stored into a huge old array,
// the case a per-object remembered set handles worst. Plus the usual per-frame garbage.
let entities = [];
for (let i = 0; i < 1000000; i++) entities.push({ id: i, x: i % 640, y: i % 480 });
let checksum = 0;
for (let frame = 0; frame < 100; frame++) {
  let slot = (frame * 7919) % entities.length;
  entities[slot] = { id: slot, x: frame, y: frame };
  for (let k = 0; k < 2000; k++) {
    let e = entities[(frame * 2000 + k) % entities.length];
    let v = { dx: (k % 3) - 1, dy: (k % 5) - 2 };
    let label = 'f' + frame + ':' + e.id;
    e.x = e.x + v.dx; e.y = e.y + v.dy;
    checksum = checksum + label.length;
  }
}
print(checksum, entities[7919].x, entities[123456].y);
