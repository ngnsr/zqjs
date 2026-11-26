// Regression diff test for language/expressions conformance fixes.

// 1. Compound & logical assignment: base null check before ToPropertyKey.
{
  const key = {
    toString() {
      return "p";
    },
  };
  const o = { p: 2 };
  o[key] += 3;
  o[key] &&= 10;
  print("propkey_assign:", o.p);

  let toStrCalled = false;
  let threwType = false;
  try {
    const k2 = {
      toString() {
        toStrCalled = true;
        return "x";
      },
    };
    null[k2] += 1;
  } catch (e) {
    threwType = e instanceof TypeError;
  }
  print("null_base_order:", threwType, toStrCalled);
}

// 2. Object literal computed key ToPropertyKey before value evaluation + fn.name.
{
  let val = "bad";
  const k = {
    toString() {
      val = "ok";
      return "p";
    },
  };
  const obj = { [k]: val };
  print("obj_key_before_val:", obj.p);

  const sym = Symbol("demo");
  const anon = Symbol();
  const o = {
    [sym]: () => {},
    [anon]: class {},
  };
  const o2 = {
    get [sym]() {},
    set [sym](v) {},
  };
  const d = Object.getOwnPropertyDescriptor(o2, sym);
  print("fn_names:", d.get.name, d.set.name, o[sym].name, o[anon].name);
}

// 3. Object rest Proxy: getOwnPropertyDescriptor not called for excluded keys.
{
  const gopdKeys = [];
  const p = new Proxy(
    {},
    {
      ownKeys() {
        return ["a", "b"];
      },
      getOwnPropertyDescriptor(_t, k) {
        gopdKeys.push(k);
        return { enumerable: true, configurable: true, value: 1 };
      },
    }
  );
  const { a, ...rest } = p;
  print("rest_proxy_gopd:", gopdKeys.join(","), rest.b);
}

// 4. Super with null proto (read throws TypeError; assign evaluates RHS first then throws TypeError).
{
  let readTypeErr = false;
  class A extends null {
    m() {
      try {
        return super.x;
      } catch (e) {
        readTypeErr = e instanceof TypeError;
      }
    }
  }
  A.prototype.m();

  let rhsCount = 0;
  let writeTypeErr = false;
  class B {
    static m() {
      super[0] = rhsCount += 1;
    }
  }
  Object.setPrototypeOf(B, null);
  try {
    B.m();
  } catch (e) {
    writeTypeErr = e instanceof TypeError;
  }
  print("super_null_proto:", readTypeErr, writeTypeErr, rhsCount);
}

// 5. Keyed destructuring evaluation order.
{
  const log = [];
  const src = () => {
    log.push("src");
    return {
      get p() {
        log.push("get");
        return 7;
      },
    };
  };
  const tgt = () => {
    log.push("tgt");
    return {
      set q(v) {
        log.push("set:" + v);
      },
    };
  };
  const sk = () => {
    log.push("sk");
    return {
      toString() {
        log.push("sk-str");
        return "p";
      },
    };
  };
  const tk = () => {
    log.push("tk");
    return {
      toString() {
        log.push("tk-str");
        return "q";
      },
    };
  };
  ({ [sk()]: tgt()[tk()] } = src());
  print("dstr_order:", log.join(","));
}

// 6. Array destructuring generator return() closes iterator.
{
  let closed = 0;
  const iterable = {
    [Symbol.iterator]() {
      return {
        next() {
          return { done: false, value: undefined };
        },
        return() {
          closed++;
          return { done: true };
        },
      };
    },
  };
  const g = function* () {
    [{} = yield] = iterable;
  };
  const it = g();
  it.next();
  const r = it.return(99);
  print("gen_dstr_close:", closed, r.value, r.done);
}

// 7. Tagged template object and raw array are frozen.
{
  let tpl = null;
  ((s) => {
    tpl = s;
  })`hi`;
  const rawDesc = Object.getOwnPropertyDescriptor(tpl, "raw");
  print("tpl_frozen:", Object.isFrozen(tpl), Object.isFrozen(tpl.raw), rawDesc.enumerable, rawDesc.writable, rawDesc.configurable);
}

// 8. Optional chaining preserves this (including parenthesized chains and super).
{
  const a = {
    _v: 42,
    b() {
      return this._v;
    },
  };
  print("opt_this:", (a?.b)(), (a.b)?.(), (a?.b)?.());

  class Base {
    m() {
      return this.tag;
    }
  }
  class Sub extends Base {
    constructor() {
      super();
      this.tag = "sub-ok";
    }
    run() {
      return super.m?.();
    }
  }
  print("opt_super:", new Sub().run());
}
