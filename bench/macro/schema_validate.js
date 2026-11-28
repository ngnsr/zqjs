// Macro benchmark: Zod-style schema validation over generated records.
// Exercises builder objects, closures, method chaining, and error objects with path arrays.
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

function makeErr(path, message) {
  return { path: path, message: message };
}

function withHelpers(base) {
  base.optional = function () {
    const inner = base;
    return withHelpers({
      _parse: function (val, path, issues) {
        if (val === undefined) return { ok: true, value: undefined };
        return inner._parse(val, path, issues);
      },
    });
  };
  base.refine = function (pred, msg) {
    const inner = base;
    return withHelpers({
      _parse: function (val, path, issues) {
        const r = inner._parse(val, path, issues);
        if (!r.ok) return r;
        if (!pred(r.value)) {
          issues.push(makeErr(path.slice(), msg));
          return { ok: false };
        }
        return r;
      },
    });
  };
  base.safeParse = function (val) {
    const issues = [];
    const r = base._parse(val, [], issues);
    if (r.ok && issues.length === 0) return { success: true, data: r.value };
    return { success: false, error: { issues: issues } };
  };
  return base;
}

const z = {
  string: function () {
    const checks = [];
    const schema = withHelpers({
      _parse: function (val, path, issues) {
        if (typeof val !== "string") {
          issues.push(makeErr(path.slice(), "expected string"));
          return { ok: false };
        }
        for (let i = 0; i < checks.length; i++) {
          const msg = checks[i](val);
          if (msg !== null) {
            issues.push(makeErr(path.slice(), msg));
            return { ok: false };
          }
        }
        return { ok: true, value: val };
      },
    });
    schema.min = function (n) {
      checks.push(function (v) { return v.length < n ? "too short" : null; });
      return schema;
    };
    schema.max = function (n) {
      checks.push(function (v) { return v.length > n ? "too long" : null; });
      return schema;
    };
    return schema;
  },

  number: function () {
    const checks = [];
    const schema = withHelpers({
      _parse: function (val, path, issues) {
        if (typeof val !== "number" || val !== val) {
          issues.push(makeErr(path.slice(), "expected number"));
          return { ok: false };
        }
        for (let i = 0; i < checks.length; i++) {
          const msg = checks[i](val);
          if (msg !== null) {
            issues.push(makeErr(path.slice(), msg));
            return { ok: false };
          }
        }
        return { ok: true, value: val };
      },
    });
    schema.int = function () {
      checks.push(function (v) { return (v | 0) !== v ? "expected int" : null; });
      return schema;
    };
    schema.min = function (n) {
      checks.push(function (v) { return v < n ? "too small" : null; });
      return schema;
    };
    schema.max = function (n) {
      checks.push(function (v) { return v > n ? "too large" : null; });
      return schema;
    };
    return schema;
  },

  boolean: function () {
    return withHelpers({
      _parse: function (val, path, issues) {
        if (typeof val !== "boolean") {
          issues.push(makeErr(path.slice(), "expected boolean"));
          return { ok: false };
        }
        return { ok: true, value: val };
      },
    });
  },

  array: function (itemSchema) {
    let minLen = 0;
    const schema = withHelpers({
      _parse: function (val, path, issues) {
        if (!Array.isArray(val)) {
          issues.push(makeErr(path.slice(), "expected array"));
          return { ok: false };
        }
        if (val.length < minLen) {
          issues.push(makeErr(path.slice(), "array too short"));
          return { ok: false };
        }
        const out = new Array(val.length);
        let allOk = true;
        for (let i = 0; i < val.length; i++) {
          path.push(i);
          const r = itemSchema._parse(val[i], path, issues);
          path.pop();
          if (r.ok) out[i] = r.value;
          else allOk = false;
        }
        return allOk ? { ok: true, value: out } : { ok: false };
      },
    });
    schema.min = function (n) {
      minLen = n;
      return schema;
    };
    return schema;
  },

  object: function (shape) {
    const keys = Object.keys(shape);
    return withHelpers({
      _parse: function (val, path, issues) {
        if (typeof val !== "object" || val === null || Array.isArray(val)) {
          issues.push(makeErr(path.slice(), "expected object"));
          return { ok: false };
        }
        const out = {};
        let allOk = true;
        for (let i = 0; i < keys.length; i++) {
          const k = keys[i];
          path.push(k);
          const r = shape[k]._parse(val[k], path, issues);
          path.pop();
          if (r.ok) {
            if (r.value !== undefined) out[k] = r.value;
          } else {
            allOk = false;
          }
        }
        return allOk ? { ok: true, value: out } : { ok: false };
      },
    });
  },
};

const orderSchema = z.object({
  id: z.number().int().min(1),
  user: z.object({
    name: z.string().min(2).max(20),
    age: z.number().int().min(18).max(120),
    vip: z.boolean().optional(),
  }),
  items: z.array(
    z.object({
      sku: z.string().min(3).max(12),
      qty: z.number().int().min(1).max(50),
      price: z.number().min(1).max(10000),
    })
  ).min(1),
}).refine(function (o) {
  return o.items.length <= 5;
}, "too many items");

const rng = makeRng(0x12345678);
const names = ["Al", "Bob", "Carol", "Dave", "Eve", "X", "VeryLongUserNameExceedingTwentyChars"];
const skus = ["SKU100", "SKU200", "AB", "SKU9999"];

const RECORDS = 25000;
let checksum = 0x811c9dc5;

for (let i = 0; i < RECORDS; i++) {
  const r = rng();
  const itemCount = (r % 6); // 0..5 (0 fails min(1))
  const items = [];
  for (let j = 0; j < itemCount; j++) {
    const rj = rng();
    items.push({
      sku: skus[rj % skus.length],
      qty: (rj % 60) - 2, // occasionally <= 0 or > 50
      price: ((rj >>> 8) % 200) + 1,
    });
  }
  const rec = {
    id: (r % 20 === 0) ? -1 : i + 1,
    user: {
      name: names[(r >>> 3) % names.length],
      age: 15 + ((r >>> 7) % 110),
      vip: (r & 1) === 0 ? true : ((r & 2) === 0 ? undefined : "bad"),
    },
    items: items,
  };

  const res = orderSchema.safeParse(rec);
  if (res.success) {
    checksum = Math.imul(checksum ^ (res.data.id + res.data.items.length), 0x01000193) >>> 0;
  } else {
    const issues = res.error.issues;
    for (let k = 0; k < issues.length; k++) {
      const iss = issues[k];
      checksum = Math.imul(checksum ^ (iss.path.length + iss.message.length), 0x01000193) >>> 0;
    }
  }
}

_print("RESULT " + checksum);
