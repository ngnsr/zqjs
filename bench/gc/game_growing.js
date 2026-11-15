// Game-like GC workload (M8.1): the long-lived set grows by 1000 entities a frame (to
// 300k) while every frame makes the same garbage. Pause against live size, collection by
// collection: with M8 the pause grows with the old generation; a minor collection
// shouldn't.
let entities = [];
let checksum = 0;
for (let frame = 0; frame < 300; frame++) {
  for (let i = 0; i < 1000; i++) {
    let id = entities.length;
    entities.push({ id: id, x: id % 640, y: id % 480, name: 'e' + id });
  }
  for (let k = 0; k < 2000; k++) {
    let e = entities[(frame * 2000 + k) % entities.length];
    let v = { dx: (k % 3) - 1, dy: (k % 5) - 2 };
    let label = 'f' + frame + ':' + e.id;
    e.x = e.x + v.dx; e.y = e.y + v.dy;
    checksum = checksum + label.length;
  }
}
print(checksum, entities.length, entities[12345].x, entities[12345].y);
