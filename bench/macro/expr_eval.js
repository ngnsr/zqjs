// Macro benchmark: Tokenizer + recursive-descent parser + evaluator for a small expression language.
// Exercises string scanning, AST node allocation, recursive calls, and environment lookups.
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

function tokenize(src) {
  const tokens = [];
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src.charCodeAt(i);
    if (c === 32 || c === 9 || c === 10) {
      i++;
      continue;
    }
    if (c >= 48 && c <= 57) {
      let start = i;
      while (i < n) {
        const d = src.charCodeAt(i);
        if (d >= 48 && d <= 57) i++;
        else break;
      }
      tokens.push({ t: "num", v: parseInt(src.slice(start, i), 10) });
      continue;
    }
    if ((c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c === 95) {
      let start = i;
      while (i < n) {
        const d = src.charCodeAt(i);
        if ((d >= 97 && d <= 122) || (d >= 65 && d <= 90) || (d >= 48 && d <= 57) || d === 95) i++;
        else break;
      }
      const word = src.slice(start, i);
      if (word === "let" || word === "if" || word === "then" || word === "else") {
        tokens.push({ t: word, v: word });
      } else {
        tokens.push({ t: "id", v: word });
      }
      continue;
    }
    const ch = src[i];
    if (ch === "+" || ch === "-" || ch === "*" || ch === "/" || ch === "%" ||
        ch === "(" || ch === ")" || ch === ";" || ch === "=" || ch === "<" || ch === ">") {
      tokens.push({ t: ch, v: ch });
      i++;
      continue;
    }
    throw new Error("unexpected char: " + ch);
  }
  tokens.push({ t: "eof", v: "" });
  return tokens;
}

function parseProgram(tokens) {
  let pos = 0;
  function peek() { return tokens[pos]; }
  function eat(t) {
    const tok = tokens[pos];
    if (tok.t !== t) throw new Error("expected " + t + ", got " + tok.t);
    pos++;
    return tok;
  }

  function parsePrimary() {
    const tok = peek();
    if (tok.t === "num") {
      pos++;
      return { k: "num", v: tok.v };
    }
    if (tok.t === "id") {
      pos++;
      return { k: "id", name: tok.v };
    }
    if (tok.t === "(") {
      pos++;
      const e = parseExpr();
      eat(")");
      return e;
    }
    if (tok.t === "if") {
      pos++;
      const cond = parseExpr();
      eat("then");
      const a = parseExpr();
      eat("else");
      const b = parseExpr();
      return { k: "if", cond: cond, a: a, b: b };
    }
    if (tok.t === "-") {
      pos++;
      return { k: "neg", x: parsePrimary() };
    }
    throw new Error("unexpected token: " + tok.t);
  }

  function parseMul() {
    let left = parsePrimary();
    while (peek().t === "*" || peek().t === "/" || peek().t === "%") {
      const op = tokens[pos++].t;
      left = { k: "bin", op: op, l: left, r: parsePrimary() };
    }
    return left;
  }

  function parseAdd() {
    let left = parseMul();
    while (peek().t === "+" || peek().t === "-") {
      const op = tokens[pos++].t;
      left = { k: "bin", op: op, l: left, r: parseMul() };
    }
    return left;
  }

  function parseCmp() {
    let left = parseAdd();
    while (peek().t === "<" || peek().t === ">") {
      const op = tokens[pos++].t;
      left = { k: "bin", op: op, l: left, r: parseAdd() };
    }
    return left;
  }

  function parseExpr() {
    return parseCmp();
  }

  const stmts = [];
  while (peek().t !== "eof") {
    if (peek().t === "let") {
      pos++;
      const name = eat("id").v;
      eat("=");
      const val = parseExpr();
      eat(";");
      stmts.push({ k: "let", name: name, val: val });
    } else {
      const e = parseExpr();
      if (peek().t === ";") pos++;
      stmts.push({ k: "expr", e: e });
    }
  }
  return stmts;
}

function evalNode(node, env) {
  if (node.k === "num") return node.v;
  if (node.k === "id") return env[node.name] | 0;
  if (node.k === "neg") return (-evalNode(node.x, env)) | 0;
  if (node.k === "if") {
    return evalNode(node.cond, env) !== 0 ? evalNode(node.a, env) : evalNode(node.b, env);
  }
  if (node.k === "bin") {
    const l = evalNode(node.l, env);
    const r = evalNode(node.r, env);
    if (node.op === "+") return (l + r) | 0;
    if (node.op === "-") return (l - r) | 0;
    if (node.op === "*") return Math.imul(l, r);
    if (node.op === "/") return r === 0 ? 0 : (l / r) | 0;
    if (node.op === "%") return r === 0 ? 0 : (l % r) | 0;
    if (node.op === "<") return l < r ? 1 : 0;
    if (node.op === ">") return l > r ? 1 : 0;
  }
  return 0;
}

function evalProgram(stmts) {
  const env = Object.create(null);
  let last = 0;
  for (let i = 0; i < stmts.length; i++) {
    const s = stmts[i];
    if (s.k === "let") {
      env[s.name] = evalNode(s.val, env);
    } else {
      last = evalNode(s.e, env);
    }
  }
  return last;
}

const rng = makeRng(0xCAFEBABE);
const PROGRAMS = 3000;
let checksum = 0x811c9dc5;

for (let i = 0; i < PROGRAMS; i++) {
  const a = (rng() % 50) + 1;
  const b = (rng() % 50) + 1;
  const c = (rng() % 20) + 2;
  const src =
    "let x = " + a + " * " + b + " + " + c + "; " +
    "let y = (x % 17) + " + (a - b) + "; " +
    "let z = if x > y then (x - y) * 3 else (y - x) + 5; " +
    "z + (if z % 2 > 0 then x / " + c + " else y * 2);";
  const tokens = tokenize(src);
  const ast = parseProgram(tokens);
  const val = evalProgram(ast);
  checksum = Math.imul(checksum ^ val, 0x01000193) >>> 0;
}

_print("RESULT " + checksum);
