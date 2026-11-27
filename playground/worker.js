// zqjs Browser WASM Playground Web Worker (zero dependencies).
// Loads ./zqjs-playground.wasm (wasm32-freestanding) and runs JS in isolation.

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8");

let exports = null;

async function instantiateWasm() {
  const url = new URL("./zqjs-playground.wasm", self.location.href);
  let instance;

  if (typeof WebAssembly.instantiateStreaming === "function") {
    try {
      const result = await WebAssembly.instantiateStreaming(fetch(url), {});
      instance = result.instance;
    } catch (_streamingErr) {
      const response = await fetch(url);
      if (!response.ok) {
        throw new Error(`Failed to fetch WASM (${response.status} ${response.statusText})`);
      }
      const bytes = await response.arrayBuffer();
      const result = await WebAssembly.instantiate(bytes, {});
      instance = result.instance;
    }
  } else {
    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(`Failed to fetch WASM (${response.status} ${response.statusText})`);
    }
    const bytes = await response.arrayBuffer();
    const result = await WebAssembly.instantiate(bytes, {});
    instance = result.instance;
  }

  exports = instance.exports;
  const verPtr = exports.zqjs_version_ptr();
  const verLen = exports.zqjs_version_len();
  const version = decoder.decode(new Uint8Array(exports.memory.buffer, verPtr, verLen));
  self.postMessage({ type: "ready", version });
}

function runEval(msg) {
  if (!exports) {
    self.postMessage({ type: "error", message: "WASM runtime is not ready yet." });
    return;
  }

  const code = typeof msg.code === "string" ? msg.code : "";
  const engineId = msg.engine === "treewalk" ? 1 : 0;
  const isModule = msg.isModule ? 1 : 0;
  const maxSteps = BigInt(msg.maxSteps || 0);
  const maxHeapBytes = Number(msg.maxHeapBytes || 0) >>> 0;

  const srcBytes = encoder.encode(code);
  let srcPtr = 0;

  try {
    if (srcBytes.length > 0) {
      srcPtr = exports.zqjs_alloc(srcBytes.length);
      if (srcPtr === 0) {
        throw new Error("WASM out of memory allocating source buffer.");
      }
      new Uint8Array(exports.memory.buffer, srcPtr, srcBytes.length).set(srcBytes);
    }

    const t0 = performance.now();
    const resPtr = exports.zqjs_eval(
      srcPtr,
      srcBytes.length,
      engineId,
      isModule,
      maxSteps,
      maxHeapBytes,
    );
    const elapsedMs = performance.now() - t0;

    if (resPtr === 0) {
      throw new Error("WASM out of memory producing evaluation result.");
    }

    const resLen = exports.zqjs_result_len();
    const jsonText = decoder.decode(new Uint8Array(exports.memory.buffer, resPtr, resLen));
    const data = JSON.parse(jsonText);
    self.postMessage({ type: "result", data, elapsedMs });
  } catch (err) {
    self.postMessage({
      type: "error",
      message: err instanceof Error ? err.message : String(err),
    });
  } finally {
    if (srcPtr !== 0 && srcBytes.length > 0) {
      try {
        exports.zqjs_free(srcPtr, srcBytes.length);
      } catch (_ignore) {
        // Ignore cleanup errors if the WASM instance trapped.
      }
    }
  }
}

self.addEventListener("message", (event) => {
  const msg = event.data;
  if (!msg || typeof msg !== "object") return;
  if (msg.type === "eval") {
    runEval(msg);
  }
});

instantiateWasm().catch((err) => {
  self.postMessage({
    type: "error",
    message: err instanceof Error ? err.message : String(err),
  });
});
