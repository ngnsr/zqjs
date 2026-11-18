// Exit kinds (normal, return, break, continue, throw) crossing 1, 2, 3 nested finally blocks.
function exitNormal(n) {
  const log = [];
  if (n === 1) {
    try {
      log.push('body');
    } finally {
      log.push('f1');
    }
  } else if (n === 2) {
    try {
      try {
        log.push('body');
      } finally {
        log.push('f1');
      }
    } finally {
      log.push('f2');
    }
  } else {
    try {
      try {
        try {
          log.push('body');
        } finally {
          log.push('f1');
        }
      } finally {
        log.push('f2');
      }
    } finally {
      log.push('f3');
    }
  }
  log.push('after');
  return log.join(',');
}
print('normal1:', exitNormal(1));
print('normal2:', exitNormal(2));
print('normal3:', exitNormal(3));

function exitReturn(n) {
  const log = [];
  function inner() {
    if (n === 1) {
      try {
        log.push('body');
        return 'r1';
      } finally {
        log.push('f1');
      }
    } else if (n === 2) {
      try {
        try {
          log.push('body');
          return 'r2';
        } finally {
          log.push('f1');
        }
      } finally {
        log.push('f2');
      }
    } else {
      try {
        try {
          try {
            log.push('body');
            return 'r3';
          } finally {
            log.push('f1');
          }
        } finally {
          log.push('f2');
        }
      } finally {
        log.push('f3');
      }
    }
  }
  const r = inner();
  return r + ':' + log.join(',');
}
print('return1:', exitReturn(1));
print('return2:', exitReturn(2));
print('return3:', exitReturn(3));

function exitThrow(n) {
  const log = [];
  try {
    if (n === 1) {
      try {
        log.push('body');
        throw 'e1';
      } finally {
        log.push('f1');
      }
    } else if (n === 2) {
      try {
        try {
          log.push('body');
          throw 'e2';
        } finally {
          log.push('f1');
        }
      } finally {
        log.push('f2');
      }
    } else {
      try {
        try {
          try {
            log.push('body');
            throw 'e3';
          } finally {
            log.push('f1');
          }
        } finally {
          log.push('f2');
        }
      } finally {
        log.push('f3');
      }
    }
  } catch (e) {
    return e + ':' + log.join(',');
  }
}
print('throw1:', exitThrow(1));
print('throw2:', exitThrow(2));
print('throw3:', exitThrow(3));

// break and continue crossing 1, 2, 3 nested finally blocks.
function exitBreakContinue() {
  const log = [];
  for (let i = 0; i < 4; i++) {
    try {
      try {
        try {
          log.push('top:' + i);
          if (i === 1) continue;
          if (i === 2) break;
          log.push('bot:' + i);
        } finally {
          log.push('f1:' + i);
        }
      } finally {
        log.push('f2:' + i);
      }
    } finally {
      log.push('f3:' + i);
    }
    log.push('end:' + i);
  }
  log.push('done');
  return log.join(',');
}
print('bc3:', exitBreakContinue());

// A continue that crosses one finally but not another.
function partialCross() {
  const log = [];
  try {
    for (let i = 0; i < 3; i++) {
      try {
        if (i === 1) continue;
        log.push('body:' + i);
      } finally {
        log.push('inner_fin:' + i);
      }
    }
  } finally {
    log.push('outer_fin');
  }
  return log.join(',');
}
print('partial:', partialCross());

// finally inside switch inside loops.
function switchFinally() {
  const log = [];
  for (let i = 0; i < 4; i++) {
    switch (i) {
      case 0:
        try {
          log.push('c0');
          break;
        } finally {
          log.push('f0');
        }
      case 1:
        try {
          log.push('c1');
          continue;
        } finally {
          log.push('f1');
        }
      case 2:
        try {
          try {
            log.push('c2');
            return log.join(',') + ':ret2';
          } finally {
            log.push('f2a');
          }
        } finally {
          log.push('f2b');
        }
    }
    log.push('after_sw:' + i);
  }
  return log.join(',');
}
print('switchFin:', switchFinally());

// Abrupt exit from nested finally inside finally.
function nestedFinallyOverride() {
  const log = [];
  for (let i = 0; i < 2; i++) {
    try {
      log.push('try:' + i);
      throw 'err:' + i;
    } finally {
      log.push('outer_fin_start:' + i);
      try {
        throw 'inner_err:' + i;
      } finally {
        log.push('inner_fin:' + i);
        if (i === 0) continue;
        break;
      }
    }
  }
  return log.join(',');
}
print('nestedOverride:', nestedFinallyOverride());
