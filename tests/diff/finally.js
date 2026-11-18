// Basic try/finally: normal, throw, return.
try {
  print('t1');
} finally {
  print('f1');
}

try {
  try {
    print('t2');
    throw 'err2';
  } finally {
    print('f2');
  }
} catch (e) {
  print('caught2:', e);
}

function retBasic() {
  try {
    print('t3');
    return 33;
  } finally {
    print('f3');
  }
}
print('retBasic:', retBasic());

// Return value overridden by finally's return.
function retOverride() {
  try {
    return 1;
  } finally {
    return 2;
  }
}
print('retOverride:', retOverride());

// Exception overridden by finally's return.
function throwOverrideRet() {
  try {
    throw 'boom';
  } finally {
    return 'saved';
  }
}
print('throwOverrideRet:', throwOverrideRet());

// Exception replaced by an exception thrown in finally.
try {
  try {
    throw 'first';
  } finally {
    throw 'second';
  }
} catch (e) {
  print('replaced:', e);
}

// try/catch/finally: normal, caught, catch rethrows, catch itself throws.
function tcf(mode) {
  try {
    print('try', mode);
    if (mode === 'throw' || mode === 'rethrow' || mode === 'catch_throw') throw 'e_' + mode;
    if (mode === 'ret') return 'from_try';
  } catch (e) {
    print('catch', e);
    if (mode === 'rethrow') throw e;
    if (mode === 'catch_throw') throw 'from_catch';
    return 'from_catch_ret';
  } finally {
    print('finally', mode);
  }
  return 'after';
}
print('tcf norm:', tcf('norm'));
print('tcf ret:', tcf('ret'));
print('tcf throw:', tcf('throw'));
try {
  tcf('rethrow');
} catch (e) {
  print('outer rethrow:', e);
}
try {
  tcf('catch_throw');
} catch (e) {
  print('outer catch_throw:', e);
}

// while (true) { try { break; } finally { ... } }
let wcount = 0;
while (true) {
  try {
    wcount += 1;
    break;
  } finally {
    print('while_break_fin', wcount);
  }
}
print('after while:', wcount);

// break and continue out of finally.
for (let i = 0; i < 4; i++) {
  try {
    if (i === 1) throw 'skip';
    if (i === 3) return_not_used();
  } catch (e) {
    print('loop catch', i, e);
  } finally {
    print('loop fin', i);
    if (i === 1) continue;
    if (i === 2) break;
  }
  print('loop body end', i);
}
function return_not_used() {
  return 0;
}

// Return object identity preserved across finally.
const sentinel = { tag: 'id' };
function retObj() {
  try {
    return sentinel;
  } finally {
    let tmp = { tag: 'other' };
    if (tmp.tag === 'nope') print(tmp.tag);
  }
}
print('obj identity:', retObj() === sentinel);

// Closures created in try, catch, and finally capturing per-iteration let bindings.
const fns = [];
for (let i = 0; i < 3; i++) {
  try {
    fns.push(() => 'try:' + i);
    if (i === 1) throw i;
  } catch (e) {
    fns.push(() => 'catch:' + i + ':' + e);
  } finally {
    fns.push(() => 'fin:' + i);
  }
}
print('closures:', fns.map((f) => f()).join(','));

// finally in arrow functions and callbacks (Array.map, Promise.then).
const mapped = [10, 20, 30].map((x) => {
  try {
    if (x === 20) return x * 2;
    return x + 1;
  } finally {
    print('map fin', x);
  }
});
print('mapped:', mapped.join(','));

Promise.resolve(5)
  .then((v) => {
    try {
      return v + 10;
    } finally {
      print('promise then fin', v);
    }
  })
  .then((v) => {
    print('promise res:', v);
  });
