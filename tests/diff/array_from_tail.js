// 1. Array.from: deleted elements & source array boundary values
{
  const original = [0, 1, -2, 4, -8, 16];
  const arr = [0, 1, -2, 4, -8, 16];
  const state = { idx: -1 };
  const mapped = Array.from(arr, function (value, index) {
    this.idx++;
    if (value !== arr[this.idx] || index !== this.idx) throw new Error('mismatch');
    arr.splice(arr.length - 1, 1);
    return 127;
  }, state);
  print('from_del:', mapped.length, mapped.join(','), original.length / 2);

  const boundary = [Number.MAX_VALUE, Number.MIN_VALUE, Number.NaN, Number.NEGATIVE_INFINITY, Number.POSITIVE_INFINITY];
  const bState = { idx: -1 };
  const bOut = Array.from(boundary, function (value, index) {
    this.idx++;
    if (!Object.is(value, boundary[this.idx]) || index !== this.idx) throw new Error('boundary mismatch');
    return value;
  }, bState);
  print(
    'from_boundary:',
    bOut.length,
    Object.is(bOut[0], Number.MAX_VALUE),
    Object.is(bOut[1], Number.MIN_VALUE),
    Object.is(bOut[2], Number.NaN),
    Object.is(bOut[3], Number.NEGATIVE_INFINITY),
    Object.is(bOut[4], Number.POSITIVE_INFINITY)
  );
}

// 2. arr.push fast-path edge cases
{
  // Normal dense push + GC pressure
  const big = [];
  for (let i = 0; i < 200; i++) {
    const r = big.push({ v: i });
    if (r !== i + 1) throw new Error('bad push len');
  }
  print('push_gc:', big.length, big[0].v, big[199].v);

  // Frozen array
  const frozen = Object.freeze([1, 2]);
  let errFrozen = '';
  try { frozen.push(3); } catch (e) { errFrozen = e.name; }
  print('push_frozen:', errFrozen, frozen.length);

  // Sealed array
  const sealed = Object.seal([1, 2]);
  let errSealed = '';
  try { sealed.push(3); } catch (e) { errSealed = e.name; }
  print('push_sealed:', errSealed, sealed.length);

  // Non-writable length
  const nwLen = [1, 2];
  Object.defineProperty(nwLen, 'length', { writable: false });
  let errNw = '';
  try { nwLen.push(3); } catch (e) { errNw = e.name; }
  print('push_nw_len:', errNw, nwLen.length);

  // Overridden Array.prototype.push
  const origPush = Array.prototype.push;
  let customCalls = 0;
  Array.prototype.push = function (x) { customCalls++; return origPush.call(this, x * 10); };
  const over = [1];
  const overLen = over.push(5);
  Array.prototype.push = origPush;
  print('push_override:', overLen, over.join(','), customCalls);

  // Proxy receiver
  const log = [];
  const pTarget = [10];
  const p = new Proxy(pTarget, {
    set(t, k, v, r) { log.push(String(k) + '=' + v); return Reflect.set(t, k, v, r); }
  });
  const pLen = p.push(20);
  print('push_proxy:', pLen, pTarget.join(','), log.join('|'));

  // Array-like object
  const al = { 0: 'a', length: 1 };
  const alLen = Array.prototype.push.call(al, 'b');
  print('push_arraylike:', alLen, al[0], al[1], al.length);

  // Mutated Array.prototype indexed setter
  let protoSet = 0;
  Object.defineProperty(Array.prototype, '1', {
    configurable: true,
    set(v) { protoSet += v; }
  });
  const pa = [10];
  pa.push(7);
  delete Array.prototype['1'];
  print('push_proto_setter:', protoSet, pa.length, 1 in pa);
}

// 3. obj[key] string-key fast-path edge cases
{
  const proto = { inherited: 42, shared: 'proto' };
  const o = Object.create(proto);
  o.w = 10;
  o.h = 20;
  o.shared = 'own';
  const kW = 'w';
  const kH = 'h';
  const kInh = 'inherited';
  const kShared = 'shared';
  const kMiss = 'missing';
  print('elem_shaped:', o[kW], o[kH], o[kInh], o[kShared], o[kMiss]);

  // Getter
  const withGetter = { a: 1 };
  let gCount = 0;
  Object.defineProperty(withGetter, 'g', {
    get() { gCount++; return 99; }
  });
  const kG = 'g';
  print('elem_getter:', withGetter[kG], gCount);

  // Deleted property (both tail and non-tail)
  const delObj = { a: 1, b: 2, c: 3 };
  delete delObj.c;
  delete delObj.a;
  const kA = 'a';
  const kB = 'b';
  const kC = 'c';
  print('elem_deleted:', delObj[kA], delObj[kB], delObj[kC]);

  // Numeric-string key "0"
  const numObj = { '0': 'zero', x: 5 };
  const k0 = '0';
  const kX = 'x';
  print('elem_num_str:', numObj[k0], numObj[kX]);

  // Dictionary-mode object (>64 props)
  const dict = {};
  for (let i = 0; i < 70; i++) dict['k' + i] = i * 3;
  const k65 = 'k65';
  const k0d = 'k0';
  print('elem_dict:', dict[k0d], dict[k65], dict['nope']);

  // Computed (non-literal) string key
  const dynKey = ['w', ''].join('');
  print('elem_dyn:', o[dynKey]);
}

// 4. Object.create edge cases
{
  const nullProto = Object.create(null);
  nullProto.x = 7;
  print('create_null:', Object.getPrototypeOf(nullProto), nullProto.x, 'toString' in nullProto);

  const p = { base: 100 };
  const withProps = Object.create(p, {
    a: { value: 1, enumerable: true },
    b: { get() { return this.base + 2; }, enumerable: true }
  });
  print('create_props:', withProps.base, withProps.a, withProps.b);

  const prims = [undefined, 42, 'str', true];
  const errs = prims.map((v) => {
    try { Object.create(v); return 'ok'; } catch (e) { return e.name; }
  });
  print('create_prim:', errs.join(','));

  const origCreate = Object.create;
  let customCreate = 0;
  Object.create = function (proto) { customCreate++; return { custom: true, p: proto }; };
  const cRes = Object.create(p);
  Object.create = origCreate;
  print('create_override:', customCreate, cRes.custom, cRes.p === p);
}
