// Macro benchmark: Class-based 2D game/physics tick with Map/Set spatial grid and array churn.
// Exercises classes, methods, Map/Set operations, and short-lived object/array allocations.
const _print = typeof print === "function" ? print : console.log;

function makeRng(seed) {
  let s = seed | 0;
  return function next() {
    s = (s + 0x6d2b79f5) | 0;
    let t = Math.imul(s ^ (s >>> 15), 1 | s);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0);
  };
}

class Vec2 {
  constructor(x, y) {
    this.x = x | 0;
    this.y = y | 0;
  }
  add(other) {
    return new Vec2(this.x + other.x, this.y + other.y);
  }
}

class Body {
  constructor(id, pos, vel, radius) {
    this.id = id;
    this.pos = pos;
    this.vel = vel;
    this.radius = radius;
    this.ttl = 120;
  }
  step(bounds) {
    this.pos = this.pos.add(this.vel);
    if (this.pos.x < 0) {
      this.pos.x = 0;
      this.vel.x = -this.vel.x;
    } else if (this.pos.x > bounds) {
      this.pos.x = bounds;
      this.vel.x = -this.vel.x;
    }
    if (this.pos.y < 0) {
      this.pos.y = 0;
      this.vel.y = -this.vel.y;
    } else if (this.pos.y > bounds) {
      this.pos.y = bounds;
      this.vel.y = -this.vel.y;
    }
    this.ttl--;
  }
}

class World {
  constructor(bounds, cellSize) {
    this.bounds = bounds;
    this.cellSize = cellSize;
    this.bodies = [];
    this.grid = new Map();
    this.collided = new Set();
    this.nextId = 1;
  }

  spawn(rng) {
    const r1 = rng();
    const r2 = rng();
    const pos = new Vec2(r1 % this.bounds, r2 % this.bounds);
    const vx = ((r1 >>> 16) % 11) - 5;
    const vy = ((r2 >>> 16) % 11) - 5;
    this.bodies.push(new Body(this.nextId++, pos, new Vec2(vx === 0 ? 1 : vx, vy === 0 ? -1 : vy), 12));
  }

  tick(rng) {
    this.grid.clear();
    this.collided.clear();

    const alive = [];
    for (let i = 0; i < this.bodies.length; i++) {
      const b = this.bodies[i];
      b.step(this.bounds);
      if (b.ttl > 0) {
        alive.push(b);
        const cx = (b.pos.x / this.cellSize) | 0;
        const cy = (b.pos.y / this.cellSize) | 0;
        const key = (cx << 10) | cy;
        let bucket = this.grid.get(key);
        if (bucket === undefined) {
          bucket = [b];
          this.grid.set(key, bucket);
        } else {
          bucket.push(b);
        }
      }
    }
    this.bodies = alive;

    let hits = 0;
    this.grid.forEach((bucket) => {
      if (bucket.length < 2) return;
      for (let i = 0; i < bucket.length; i++) {
        const a = bucket[i];
        for (let j = i + 1; j < bucket.length; j++) {
          const b = bucket[j];
          const dx = a.pos.x - b.pos.x;
          const dy = a.pos.y - b.pos.y;
          const dist2 = dx * dx + dy * dy;
          const rad = a.radius + b.radius;
          if (dist2 <= rad * rad) {
            const pairKey = a.id < b.id ? (a.id * 65536 + b.id) : (b.id * 65536 + a.id);
            if (!this.collided.has(pairKey)) {
              this.collided.add(pairKey);
              const tvx = a.vel.x;
              const tvy = a.vel.y;
              a.vel.x = b.vel.x;
              a.vel.y = b.vel.y;
              b.vel.x = tvx;
              b.vel.y = tvy;
              hits++;
            }
          }
        }
      }
    });

    while (this.bodies.length < 180) {
      this.spawn(rng);
    }
    return hits;
  }
}

const rng = makeRng(0xDEADBEEF);
const world = new World(1024, 64);
for (let i = 0; i < 180; i++) world.spawn(rng);

let totalHits = 0;
const TICKS = 1200;
for (let t = 0; t < TICKS; t++) {
  totalHits += world.tick(rng);
}

let checksum = totalHits | 0;
for (let i = 0; i < world.bodies.length; i++) {
  const b = world.bodies[i];
  checksum = Math.imul(checksum ^ (b.pos.x * 31 + b.pos.y + b.id), 0x01000193) >>> 0;
}

_print("RESULT " + checksum);
