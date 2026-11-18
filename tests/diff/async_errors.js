// Async error handling: synchronous throw, rejected await, try/catch
async function syncThrow() {
  throw "sync_boom";
}
const pSync = syncThrow();
print("syncThrow returned promise");
pSync.catch(e => print("syncThrow caught:", e));

async function catchRejected() {
  try {
    await Promise.reject("bad");
    return "unreachable";
  } catch (e) {
    return "caught:" + e;
  }
}
catchRejected().then(v => print("catchRejected:", v));

async function catchPendingReject() {
  let rej = null;
  const p = new Promise((_, r) => { rej = r; });
  Promise.resolve().then(() => rej("later"));
  try {
    await p;
  } catch (e) {
    return "pending_caught:" + e;
  }
}
catchPendingReject().then(v => print("catchPendingReject:", v));

async function rethrowAsync() {
  try {
    await Promise.reject("e1");
  } catch (e) {
    await Promise.reject("e2:" + e);
  }
}
rethrowAsync().catch(e => print("rethrowAsync:", e));

async function uncaughtTypeError() {
  const x = null;
  return x.prop;
}
uncaughtTypeError().catch(e => print("uncaughtTypeError:", e.name));
