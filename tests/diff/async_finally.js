// Async + try/finally interactions (D55 x D56)
const log = [];
function cleanup(tag) {
  log.push(tag);
}

async function returnWithFinally() {
  try {
    return await Promise.resolve(1);
  } finally {
    cleanup("finally1");
  }
}
returnWithFinally().then(v => print("retFinally:", v, log.join(",")));

async function awaitInCatchAndFinally() {
  const trace = [];
  try {
    await Promise.reject("err");
  } catch (e) {
    trace.push("catch:" + await Promise.resolve(e));
    return "from_catch";
  } finally {
    trace.push("fin:" + await Promise.resolve("ok"));
  }
  return trace;
}
awaitInCatchAndFinally().then(v => print("catchFinally:", v));

async function finallyOverrideReturn() {
  try {
    return await Promise.resolve("orig");
  } finally {
    await Promise.resolve(0);
    return "override";
  }
}
finallyOverrideReturn().then(v => print("override:", v));

async function finallyBreakAndContinue() {
  const out = [];
  for (let i = 0; i < 4; i++) {
    try {
      if (i === 1) continue;
      if (i === 3) break;
      out.push("body:" + await Promise.resolve(i));
    } finally {
      out.push("fin:" + await Promise.resolve(i));
    }
  }
  return out.join(",");
}
finallyBreakAndContinue().then(v => print("loopFinally:", v));

async function nestedFinallyThrow() {
  const trace = [];
  try {
    try {
      return await Promise.resolve("inner");
    } finally {
      trace.push("f1:" + await Promise.resolve(1));
    }
  } finally {
    trace.push("f2:" + await Promise.resolve(2));
  }
}
nestedFinallyThrow().then(v => print("nestedFinally:", v));
