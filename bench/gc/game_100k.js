// Game-like GC workload (M8.1): 100k long-lived entities, then frames that each make
// short-lived garbage (a velocity object and a label string per update). Collections
// during the frames show what a steady game loop pays with a big old generation.
let entities = [];
for (let i = 0; i < 100000; i++) entities.push({ id: i, x: i % 640, y: i % 480, name: 'e' + i });
let checksum = 0;
for (let frame = 0; frame < 300; frame++) {
  for (let k = 0; k < 2000; k++) {
    let e = entities[(frame * 2000 + k) % entities.length];
    let v = { dx: (k % 3) - 1, dy: (k % 5) - 2 };
    let label = 'f' + frame + ':' + e.id;
    e.x = e.x + v.dx; e.y = e.y + v.dy;
    checksum = checksum + label.length;
  }
}
print(checksum, entities[12345].x, entities[12345].y);
