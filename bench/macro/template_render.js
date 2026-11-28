// Macro benchmark: String templating and markdown-lite rendering with RegExp and string building.
// Exercises RegExp matching/replacing, array joins, and string concatenation.
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

const reVar = /\{\{(\w+)\}\}/g;
const reBold = /\*\*([^*]+)\*\*/g;
const reCode = /`([^`]+)`/g;
const reLink = /\[([^\]]+)\]\(([^)]+)\)/g;

function interpolate(tpl, ctx) {
  return tpl.replace(reVar, function (_, key) {
    const v = ctx[key];
    return v !== undefined ? String(v) : "";
  });
}

function renderMarkdownLite(md) {
  const lines = md.split("\n");
  const out = [];
  let inList = false;

  for (let i = 0; i < lines.length; i++) {
    let line = lines[i];
    if (line.indexOf("# ") === 0) {
      if (inList) { out.push("</ul>"); inList = false; }
      line = "<h1>" + line.slice(2) + "</h1>";
      out.push(line);
      continue;
    }
    if (line.indexOf("## ") === 0) {
      if (inList) { out.push("</ul>"); inList = false; }
      line = "<h2>" + line.slice(3) + "</h2>";
      out.push(line);
      continue;
    }
    if (line.indexOf("- ") === 0) {
      if (!inList) { out.push("<ul>"); inList = true; }
      let body = line.slice(2);
      body = body.replace(reBold, "<strong>$1</strong>");
      body = body.replace(reCode, "<code>$1</code>");
      body = body.replace(reLink, '<a href="$2">$1</a>');
      out.push("<li>" + body + "</li>");
      continue;
    }
    if (inList) { out.push("</ul>"); inList = false; }
    if (line.length === 0) continue;
    line = line.replace(reBold, "<strong>$1</strong>");
    line = line.replace(reCode, "<code>$1</code>");
    line = line.replace(reLink, '<a href="$2">$1</a>');
    out.push("<p>" + line + "</p>");
  }
  if (inList) out.push("</ul>");
  return out.join("\n");
}

function fnv1a(str, seed) {
  let h = seed >>> 0;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h;
}

const template =
  "# Release {{version}} ({{codename}})\n" +
  "Summary for **{{owner}}**: `{{count}}` items processed.\n" +
  "## Highlights\n" +
  "- Added **{{feature}}** via `{{module}}`\n" +
  "- Fixed [issue #{{issue}}](https://example.org/{{issue}}) in `{{module}}`\n" +
  "- Tuned **{{metric}}** budget to `{{budget}}` ms\n" +
  "See [changelog](https://example.org/log/{{version}}) for details.";

const owners = ["alice", "bob", "carol", "dave"];
const features = ["fast-ic", "slab-pool", "nursery-gc", "peephole"];
const modules = ["vm.zig", "heap.zig", "compiler.zig", "parser.zig"];
const metrics = ["p99", "throughput", "rss", "startup"];

const rng = makeRng(0x55AA55AA);
const DOCS = 2500;
let checksum = 0x811c9dc5;

for (let i = 0; i < DOCS; i++) {
  const r = rng();
  const ctx = {
    version: "1." + (r % 20) + "." + (i % 10),
    codename: "c" + (r & 255),
    owner: owners[r % owners.length],
    count: (r >>> 4) % 500,
    feature: features[(r >>> 8) % features.length],
    module: modules[(r >>> 12) % modules.length],
    issue: 100 + (r % 900),
    metric: metrics[(r >>> 16) % metrics.length],
    budget: 5 + (r % 50),
  };
  const md = interpolate(template, ctx);
  const html = renderMarkdownLite(md);
  checksum = fnv1a(html, checksum);
}

_print("RESULT " + checksum);
