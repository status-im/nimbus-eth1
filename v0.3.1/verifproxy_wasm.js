
var VerifProxyModule = (() => {
  var _scriptName = import.meta.url;
  
  return (
async function(moduleArg = {}) {
  var moduleRtn;

// Support for growable heap + pthreads, where the buffer may change, so JS views
// must be updated.
function GROWABLE_HEAP_I8() {
  if (wasmMemory.buffer != HEAP8.buffer) {
    updateMemoryViews();
  }
  return HEAP8;
}
function GROWABLE_HEAP_U8() {
  if (wasmMemory.buffer != HEAP8.buffer) {
    updateMemoryViews();
  }
  return HEAPU8;
}
function GROWABLE_HEAP_I16() {
  if (wasmMemory.buffer != HEAP8.buffer) {
    updateMemoryViews();
  }
  return HEAP16;
}
function GROWABLE_HEAP_U16() {
  if (wasmMemory.buffer != HEAP8.buffer) {
    updateMemoryViews();
  }
  return HEAPU16;
}
function GROWABLE_HEAP_I32() {
  if (wasmMemory.buffer != HEAP8.buffer) {
    updateMemoryViews();
  }
  return HEAP32;
}
function GROWABLE_HEAP_U32() {
  if (wasmMemory.buffer != HEAP8.buffer) {
    updateMemoryViews();
  }
  return HEAPU32;
}
function GROWABLE_HEAP_F32() {
  if (wasmMemory.buffer != HEAP8.buffer) {
    updateMemoryViews();
  }
  return HEAPF32;
}
function GROWABLE_HEAP_F64() {
  if (wasmMemory.buffer != HEAP8.buffer) {
    updateMemoryViews();
  }
  return HEAPF64;
}

// include: shell.js
// The Module object: Our interface to the outside world. We import
// and export values on it. There are various ways Module can be used:
// 1. Not defined. We create it here
// 2. A function parameter, function(moduleArg) => Promise<Module>
// 3. pre-run appended it, var Module = {}; ..generated code..
// 4. External script tag defines var Module.
// We need to check if Module already exists (e.g. case 3 above).
// Substitution will be replaced with actual code on later stage of the build,
// this way Closure Compiler will not mangle it (e.g. case 4. above).
// Note that if you want to run closure, and also to use Module
// after the generated code, you will need to define   var Module = {};
// before the code. Then that object will be used in the code, and you
// can continue to use Module afterwards as well.
var Module = moduleArg;

// Set up the promise that indicates the Module is initialized
var readyPromiseResolve, readyPromiseReject;

var readyPromise = new Promise((resolve, reject) => {
  readyPromiseResolve = resolve;
  readyPromiseReject = reject;
});

// Determine the runtime environment we are in. You can customize this by
// setting the ENVIRONMENT setting at compile time (see settings.js).
// Attempt to auto-detect the environment
var ENVIRONMENT_IS_WEB = typeof window == "object";

var ENVIRONMENT_IS_WORKER = typeof WorkerGlobalScope != "undefined";

// N.b. Electron.js environment is simultaneously a NODE-environment, but
// also a web environment.
var ENVIRONMENT_IS_NODE = typeof process == "object" && typeof process.versions == "object" && typeof process.versions.node == "string" && process.type != "renderer";

var ENVIRONMENT_IS_SHELL = !ENVIRONMENT_IS_WEB && !ENVIRONMENT_IS_NODE && !ENVIRONMENT_IS_WORKER;

// Three configurations we can be running in:
// 1) We could be the application main() thread running in the main JS UI thread. (ENVIRONMENT_IS_WORKER == false and ENVIRONMENT_IS_PTHREAD == false)
// 2) We could be the application main() thread proxied to worker. (with Emscripten -sPROXY_TO_WORKER) (ENVIRONMENT_IS_WORKER == true, ENVIRONMENT_IS_PTHREAD == false)
// 3) We could be an application pthread running in a worker. (ENVIRONMENT_IS_WORKER == true and ENVIRONMENT_IS_PTHREAD == true)
// The way we signal to a worker that it is hosting a pthread is to construct
// it with a specific name.
var ENVIRONMENT_IS_PTHREAD = ENVIRONMENT_IS_WORKER && self.name?.startsWith("em-pthread");

if (ENVIRONMENT_IS_NODE) {
  // `require()` is no-op in an ESM module, use `createRequire()` to construct
  // the require()` function.  This is only necessary for multi-environment
  // builds, `-sENVIRONMENT=node` emits a static import declaration instead.
  // TODO: Swap all `require()`'s with `import()`'s?
  const {createRequire} = await import("module");
  let dirname = import.meta.url;
  if (dirname.startsWith("data:")) {
    dirname = "/";
  }
  /** @suppress{duplicate} */ var require = createRequire(dirname);
  var worker_threads = require("worker_threads");
  global.Worker = worker_threads.Worker;
  ENVIRONMENT_IS_WORKER = !worker_threads.isMainThread;
  // Under node we set `workerData` to `em-pthread` to signal that the worker
  // is hosting a pthread.
  ENVIRONMENT_IS_PTHREAD = ENVIRONMENT_IS_WORKER && worker_threads["workerData"] == "em-pthread";
}

// --pre-jses are emitted after the Module integration code, so that they can
// refer to Module (if they choose; they can also define Module)
// Sometimes an existing Module object exists with properties
// meant to overwrite the default module functionality. Here
// we collect those properties and reapply _after_ we configure
// the current environment's defaults to avoid having to be so
// defensive during initialization.
var moduleOverrides = Object.assign({}, Module);

var arguments_ = [];

var thisProgram = "./this.program";

var quit_ = (status, toThrow) => {
  throw toThrow;
};

// `/` should be present at the end if `scriptDirectory` is not empty
var scriptDirectory = "";

function locateFile(path) {
  if (Module["locateFile"]) {
    return Module["locateFile"](path, scriptDirectory);
  }
  return scriptDirectory + path;
}

// Hooks that are implemented differently in different runtime environments.
var readAsync, readBinary;

if (ENVIRONMENT_IS_NODE) {
  // These modules will usually be used on Node.js. Load them eagerly to avoid
  // the complexity of lazy-loading.
  var fs = require("fs");
  var nodePath = require("path");
  // EXPORT_ES6 + ENVIRONMENT_IS_NODE always requires use of import.meta.url,
  // since there's no way getting the current absolute path of the module when
  // support for that is not available.
  if (!import.meta.url.startsWith("data:")) {
    scriptDirectory = nodePath.dirname(require("url").fileURLToPath(import.meta.url)) + "/";
  }
  // include: node_shell_read.js
  readBinary = filename => {
    // We need to re-wrap `file://` strings to URLs. Normalizing isn't
    // necessary in that case, the path should already be absolute.
    filename = isFileURI(filename) ? new URL(filename) : nodePath.normalize(filename);
    var ret = fs.readFileSync(filename);
    return ret;
  };
  readAsync = (filename, binary = true) => {
    // See the comment in the `readBinary` function.
    filename = isFileURI(filename) ? new URL(filename) : nodePath.normalize(filename);
    return new Promise((resolve, reject) => {
      fs.readFile(filename, binary ? undefined : "utf8", (err, data) => {
        if (err) reject(err); else resolve(binary ? data.buffer : data);
      });
    });
  };
  // end include: node_shell_read.js
  if (!Module["thisProgram"] && process.argv.length > 1) {
    thisProgram = process.argv[1].replace(/\\/g, "/");
  }
  arguments_ = process.argv.slice(2);
  // MODULARIZE will export the module in the proper place outside, we don't need to export here
  quit_ = (status, toThrow) => {
    process.exitCode = status;
    throw toThrow;
  };
} else // Note that this includes Node.js workers when relevant (pthreads is enabled).
// Node.js workers are detected as a combination of ENVIRONMENT_IS_WORKER and
// ENVIRONMENT_IS_NODE.
if (ENVIRONMENT_IS_WEB || ENVIRONMENT_IS_WORKER) {
  if (ENVIRONMENT_IS_WORKER) {
    // Check worker, not web, since window could be polyfilled
    scriptDirectory = self.location.href;
  } else if (typeof document != "undefined" && document.currentScript) {
    // web
    scriptDirectory = document.currentScript.src;
  }
  // When MODULARIZE, this JS may be executed later, after document.currentScript
  // is gone, so we saved it, and we use it here instead of any other info.
  if (_scriptName) {
    scriptDirectory = _scriptName;
  }
  // blob urls look like blob:http://site.com/etc/etc and we cannot infer anything from them.
  // otherwise, slice off the final part of the url to find the script directory.
  // if scriptDirectory does not contain a slash, lastIndexOf will return -1,
  // and scriptDirectory will correctly be replaced with an empty string.
  // If scriptDirectory contains a query (starting with ?) or a fragment (starting with #),
  // they are removed because they could contain a slash.
  if (scriptDirectory.startsWith("blob:")) {
    scriptDirectory = "";
  } else {
    scriptDirectory = scriptDirectory.substr(0, scriptDirectory.replace(/[?#].*/, "").lastIndexOf("/") + 1);
  }
  // Differentiate the Web Worker from the Node Worker case, as reading must
  // be done differently.
  if (!ENVIRONMENT_IS_NODE) {
    // include: web_or_worker_shell_read.js
    if (ENVIRONMENT_IS_WORKER) {
      readBinary = url => {
        var xhr = new XMLHttpRequest;
        xhr.open("GET", url, false);
        xhr.responseType = "arraybuffer";
        xhr.send(null);
        return new Uint8Array(/** @type{!ArrayBuffer} */ (xhr.response));
      };
    }
    readAsync = url => {
      // Fetch has some additional restrictions over XHR, like it can't be used on a file:// url.
      // See https://github.com/github/fetch/pull/92#issuecomment-140665932
      // Cordova or Electron apps are typically loaded from a file:// url.
      // So use XHR on webview if URL is a file URL.
      if (isFileURI(url)) {
        return new Promise((resolve, reject) => {
          var xhr = new XMLHttpRequest;
          xhr.open("GET", url, true);
          xhr.responseType = "arraybuffer";
          xhr.onload = () => {
            if (xhr.status == 200 || (xhr.status == 0 && xhr.response)) {
              // file URLs can return 0
              resolve(xhr.response);
              return;
            }
            reject(xhr.status);
          };
          xhr.onerror = reject;
          xhr.send(null);
        });
      }
      return fetch(url, {
        credentials: "same-origin"
      }).then(response => {
        if (response.ok) {
          return response.arrayBuffer();
        }
        return Promise.reject(new Error(response.status + " : " + response.url));
      });
    };
  }
} else // end include: web_or_worker_shell_read.js
{}

// Set up the out() and err() hooks, which are how we can print to stdout or
// stderr, respectively.
// Normally just binding console.log/console.error here works fine, but
// under node (with workers) we see missing/out-of-order messages so route
// directly to stdout and stderr.
// See https://github.com/emscripten-core/emscripten/issues/14804
var defaultPrint = console.log.bind(console);

var defaultPrintErr = console.error.bind(console);

if (ENVIRONMENT_IS_NODE) {
  defaultPrint = (...args) => fs.writeSync(1, args.join(" ") + "\n");
  defaultPrintErr = (...args) => fs.writeSync(2, args.join(" ") + "\n");
}

var out = Module["print"] || defaultPrint;

var err = Module["printErr"] || defaultPrintErr;

// Merge back in the overrides
Object.assign(Module, moduleOverrides);

// Free the object hierarchy contained in the overrides, this lets the GC
// reclaim data used.
moduleOverrides = null;

// Emit code to handle expected values on the Module object. This applies Module.x
// to the proper local x. This has two benefits: first, we only emit it if it is
// expected to arrive, and second, by using a local everywhere else that can be
// minified.
if (Module["arguments"]) arguments_ = Module["arguments"];

if (Module["thisProgram"]) thisProgram = Module["thisProgram"];

// perform assertions in shell.js after we set up out() and err(), as otherwise if an assertion fails it cannot print the message
// end include: shell.js
// include: preamble.js
// === Preamble library stuff ===
// Documentation for the public APIs defined in this file must be updated in:
//    site/source/docs/api_reference/preamble.js.rst
// A prebuilt local version of the documentation is available at:
//    site/build/text/docs/api_reference/preamble.js.txt
// You can also build docs locally as HTML or other formats in site/
// An online HTML version (which may be of a different version of Emscripten)
//    is up at http://kripken.github.io/emscripten-site/docs/api_reference/preamble.js.html
var wasmBinary = Module["wasmBinary"];

// Wasm globals
var wasmMemory;

// For sending to workers.
var wasmModule;

//========================================
// Runtime essentials
//========================================
// whether we are quitting the application. no code should run after this.
// set in exit() and abort()
var ABORT = false;

// set by exit() and abort().  Passed to 'onExit' handler.
// NOTE: This is also used as the process return code code in shell environments
// but only when noExitRuntime is false.
var EXITSTATUS;

// In STRICT mode, we only define assert() when ASSERTIONS is set.  i.e. we
// don't define it at all in release modes.  This matches the behaviour of
// MINIMAL_RUNTIME.
// TODO(sbc): Make this the default even without STRICT enabled.
/** @type {function(*, string=)} */ function assert(condition, text) {
  if (!condition) {
    // This build was created without ASSERTIONS defined.  `assert()` should not
    // ever be called in this configuration but in case there are callers in
    // the wild leave this simple abort() implementation here for now.
    abort(text);
  }
}

// Memory management
var HEAP, /** @type {!Int8Array} */ HEAP8, /** @type {!Uint8Array} */ HEAPU8, /** @type {!Int16Array} */ HEAP16, /** @type {!Uint16Array} */ HEAPU16, /** @type {!Int32Array} */ HEAP32, /** @type {!Uint32Array} */ HEAPU32, /** @type {!Float32Array} */ HEAPF32, /** @type {!Float64Array} */ HEAPF64;

// include: runtime_shared.js
function updateMemoryViews() {
  var b = wasmMemory.buffer;
  Module["HEAP8"] = HEAP8 = new Int8Array(b);
  Module["HEAP16"] = HEAP16 = new Int16Array(b);
  Module["HEAPU8"] = HEAPU8 = new Uint8Array(b);
  Module["HEAPU16"] = HEAPU16 = new Uint16Array(b);
  Module["HEAP32"] = HEAP32 = new Int32Array(b);
  Module["HEAPU32"] = HEAPU32 = new Uint32Array(b);
  Module["HEAPF32"] = HEAPF32 = new Float32Array(b);
  Module["HEAPF64"] = HEAPF64 = new Float64Array(b);
}

// end include: runtime_shared.js
// include: runtime_pthread.js
// Pthread Web Worker handling code.
// This code runs only on pthread web workers and handles pthread setup
// and communication with the main thread via postMessage.
if (ENVIRONMENT_IS_PTHREAD) {
  var wasmModuleReceived;
  // Node.js support
  if (ENVIRONMENT_IS_NODE) {
    // Create as web-worker-like an environment as we can.
    var parentPort = worker_threads["parentPort"];
    parentPort.on("message", msg => onmessage({
      data: msg
    }));
    Object.assign(globalThis, {
      self: global,
      postMessage: msg => parentPort.postMessage(msg)
    });
  }
  // Thread-local guard variable for one-time init of the JS state
  var initializedJS = false;
  function threadPrintErr(...args) {
    var text = args.join(" ");
    // See https://github.com/emscripten-core/emscripten/issues/14804
    if (ENVIRONMENT_IS_NODE) {
      fs.writeSync(2, text + "\n");
      return;
    }
    console.error(text);
  }
  if (!Module["printErr"]) err = threadPrintErr;
  function threadAlert(...args) {
    var text = args.join(" ");
    postMessage({
      cmd: "alert",
      text,
      threadId: _pthread_self()
    });
  }
  self.alert = threadAlert;
  // Turn unhandled rejected promises into errors so that the main thread will be
  // notified about them.
  self.onunhandledrejection = e => {
    throw e.reason || e;
  };
  function handleMessage(e) {
    try {
      var msgData = e["data"];
      //dbg('msgData: ' + Object.keys(msgData));
      var cmd = msgData.cmd;
      if (cmd === "load") {
        // Preload command that is called once per worker to parse and load the Emscripten code.
        // Until we initialize the runtime, queue up any further incoming messages.
        let messageQueue = [];
        self.onmessage = e => messageQueue.push(e);
        // And add a callback for when the runtime is initialized.
        self.startWorker = instance => {
          // Notify the main thread that this thread has loaded.
          postMessage({
            cmd: "loaded"
          });
          // Process any messages that were queued before the thread was ready.
          for (let msg of messageQueue) {
            handleMessage(msg);
          }
          // Restore the real message handler.
          self.onmessage = handleMessage;
        };
        // Use `const` here to ensure that the variable is scoped only to
        // that iteration, allowing safe reference from a closure.
        for (const handler of msgData.handlers) {
          // The the main module has a handler for a certain even, but no
          // handler exists on the pthread worker, then proxy that handler
          // back to the main thread.
          if (!Module[handler] || Module[handler].proxy) {
            Module[handler] = (...args) => {
              postMessage({
                cmd: "callHandler",
                handler,
                args
              });
            };
            // Rebind the out / err handlers if needed
            if (handler == "print") out = Module[handler];
            if (handler == "printErr") err = Module[handler];
          }
        }
        wasmMemory = msgData.wasmMemory;
        updateMemoryViews();
        wasmModuleReceived(msgData.wasmModule);
      } else if (cmd === "run") {
        // Call inside JS module to set up the stack frame for this pthread in JS module scope.
        // This needs to be the first thing that we do, as we cannot call to any C/C++ functions
        // until the thread stack is initialized.
        establishStackSpace(msgData.pthread_ptr);
        // Pass the thread address to wasm to store it for fast access.
        __emscripten_thread_init(msgData.pthread_ptr, /*is_main=*/ 0, /*is_runtime=*/ 0, /*can_block=*/ 1, 0, 0);
        PThread.receiveObjectTransfer(msgData);
        PThread.threadInitTLS();
        // Await mailbox notifications with `Atomics.waitAsync` so we can start
        // using the fast `Atomics.notify` notification path.
        __emscripten_thread_mailbox_await(msgData.pthread_ptr);
        if (!initializedJS) {
          initializedJS = true;
        }
        try {
          invokeEntryPoint(msgData.start_routine, msgData.arg);
        } catch (ex) {
          if (ex != "unwind") {
            // The pthread "crashed".  Do not call `_emscripten_thread_exit` (which
            // would make this thread joinable).  Instead, re-throw the exception
            // and let the top level handler propagate it back to the main thread.
            throw ex;
          }
        }
      } else if (msgData.target === "setimmediate") {} else // no-op
      if (cmd === "checkMailbox") {
        if (initializedJS) {
          checkMailbox();
        }
      } else if (cmd) {
        // The received message looks like something that should be handled by this message
        // handler, (since there is a cmd field present), but is not one of the
        // recognized commands:
        err(`worker: received unknown command ${cmd}`);
        err(msgData);
      }
    } catch (ex) {
      __emscripten_thread_crashed();
      throw ex;
    }
  }
  self.onmessage = handleMessage;
}

// ENVIRONMENT_IS_PTHREAD
// end include: runtime_pthread.js
// In non-standalone/normal mode, we create the memory here.
// include: runtime_init_memory.js
// Create the wasm memory. (Note: this only applies if IMPORTED_MEMORY is defined)
// check for full engine support (use string 'subarray' to avoid closure compiler confusion)
if (!ENVIRONMENT_IS_PTHREAD) {
  if (Module["wasmMemory"]) {
    wasmMemory = Module["wasmMemory"];
  } else {
    var INITIAL_MEMORY = Module["INITIAL_MEMORY"] || 536870912;
    /** @suppress {checkTypes} */ wasmMemory = new WebAssembly.Memory({
      "initial": INITIAL_MEMORY / 65536,
      // In theory we should not need to emit the maximum if we want "unlimited"
      // or 4GB of memory, but VMs error on that atm, see
      // https://github.com/emscripten-core/emscripten/issues/14130
      // And in the pthreads case we definitely need to emit a maximum. So
      // always emit one.
      "maximum": 32768,
      "shared": true
    });
  }
  updateMemoryViews();
}

// end include: runtime_init_memory.js
// include: runtime_stack_check.js
// end include: runtime_stack_check.js
var __ATPRERUN__ = [];

// functions called before the runtime is initialized
var __ATINIT__ = [];

// functions called during startup
var __ATEXIT__ = [];

// functions called during shutdown
var __ATPOSTRUN__ = [];

// functions called after the main() is called
var runtimeInitialized = false;

function preRun() {
  if (Module["preRun"]) {
    if (typeof Module["preRun"] == "function") Module["preRun"] = [ Module["preRun"] ];
    while (Module["preRun"].length) {
      addOnPreRun(Module["preRun"].shift());
    }
  }
  callRuntimeCallbacks(__ATPRERUN__);
}

function initRuntime() {
  runtimeInitialized = true;
  if (ENVIRONMENT_IS_PTHREAD) return;
  SOCKFS.root = FS.mount(SOCKFS, {}, null);
  if (!Module["noFSInit"] && !FS.initialized) FS.init();
  FS.ignorePermissions = false;
  TTY.init();
  callRuntimeCallbacks(__ATINIT__);
}

function postRun() {
  if (ENVIRONMENT_IS_PTHREAD) return;
  // PThreads reuse the runtime from the main thread.
  if (Module["postRun"]) {
    if (typeof Module["postRun"] == "function") Module["postRun"] = [ Module["postRun"] ];
    while (Module["postRun"].length) {
      addOnPostRun(Module["postRun"].shift());
    }
  }
  callRuntimeCallbacks(__ATPOSTRUN__);
}

function addOnPreRun(cb) {
  __ATPRERUN__.unshift(cb);
}

function addOnInit(cb) {
  __ATINIT__.unshift(cb);
}

function addOnExit(cb) {}

function addOnPostRun(cb) {
  __ATPOSTRUN__.unshift(cb);
}

// include: runtime_math.js
// https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Math/imul
// https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Math/fround
// https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Math/clz32
// https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Math/trunc
// end include: runtime_math.js
// A counter of dependencies for calling run(). If we need to
// do asynchronous work before running, increment this and
// decrement it. Incrementing must happen in a place like
// Module.preRun (used by emcc to add file preloading).
// Note that you can add dependencies in preRun, even though
// it happens right before run - run will be postponed until
// the dependencies are met.
var runDependencies = 0;

var runDependencyWatcher = null;

var dependenciesFulfilled = null;

// overridden to take different actions when all run dependencies are fulfilled
function getUniqueRunDependency(id) {
  return id;
}

function addRunDependency(id) {
  runDependencies++;
  Module["monitorRunDependencies"]?.(runDependencies);
}

function removeRunDependency(id) {
  runDependencies--;
  Module["monitorRunDependencies"]?.(runDependencies);
  if (runDependencies == 0) {
    if (runDependencyWatcher !== null) {
      clearInterval(runDependencyWatcher);
      runDependencyWatcher = null;
    }
    if (dependenciesFulfilled) {
      var callback = dependenciesFulfilled;
      dependenciesFulfilled = null;
      callback();
    }
  }
}

/** @param {string|number=} what */ function abort(what) {
  Module["onAbort"]?.(what);
  what = "Aborted(" + what + ")";
  // TODO(sbc): Should we remove printing and leave it up to whoever
  // catches the exception?
  err(what);
  ABORT = true;
  what += ". Build with -sASSERTIONS for more info.";
  // Use a wasm runtime error, because a JS error might be seen as a foreign
  // exception, which means we'd run destructors on it. We need the error to
  // simply make the program stop.
  // FIXME This approach does not work in Wasm EH because it currently does not assume
  // all RuntimeErrors are from traps; it decides whether a RuntimeError is from
  // a trap or not based on a hidden field within the object. So at the moment
  // we don't have a way of throwing a wasm trap from JS. TODO Make a JS API that
  // allows this in the wasm spec.
  // Suppress closure compiler warning here. Closure compiler's builtin extern
  // definition for WebAssembly.RuntimeError claims it takes no arguments even
  // though it can.
  // TODO(https://github.com/google/closure-compiler/pull/3913): Remove if/when upstream closure gets fixed.
  /** @suppress {checkTypes} */ var e = new WebAssembly.RuntimeError(what);
  readyPromiseReject(e);
  // Throw the error whether or not MODULARIZE is set because abort is used
  // in code paths apart from instantiation where an exception is expected
  // to be thrown when abort is called.
  throw e;
}

// include: memoryprofiler.js
// end include: memoryprofiler.js
// include: URIUtils.js
// Prefix of data URIs emitted by SINGLE_FILE and related options.
var dataURIPrefix = "data:application/octet-stream;base64,";

/**
 * Indicates whether filename is a base64 data URI.
 * @noinline
 */ var isDataURI = filename => filename.startsWith(dataURIPrefix);

/**
 * Indicates whether filename is delivered via file protocol (as opposed to http/https)
 * @noinline
 */ var isFileURI = filename => filename.startsWith("file://");

// end include: URIUtils.js
// include: runtime_exceptions.js
// end include: runtime_exceptions.js
function findWasmBinary() {
  if (Module["locateFile"]) {
    var f = "verifproxy_wasm.wasm";
    if (!isDataURI(f)) {
      return locateFile(f);
    }
    return f;
  }
  // Use bundler-friendly `new URL(..., import.meta.url)` pattern; works in browsers too.
  return new URL("verifproxy_wasm.wasm", import.meta.url).href;
}

var wasmBinaryFile;

function getBinarySync(file) {
  if (file == wasmBinaryFile && wasmBinary) {
    return new Uint8Array(wasmBinary);
  }
  if (readBinary) {
    return readBinary(file);
  }
  throw "both async and sync fetching of the wasm failed";
}

function getBinaryPromise(binaryFile) {
  // If we don't have the binary yet, load it asynchronously using readAsync.
  if (!wasmBinary) {
    // Fetch the binary using readAsync
    return readAsync(binaryFile).then(response => new Uint8Array(/** @type{!ArrayBuffer} */ (response)), // Fall back to getBinarySync if readAsync fails
    () => getBinarySync(binaryFile));
  }
  // Otherwise, getBinarySync should be able to get it synchronously
  return Promise.resolve().then(() => getBinarySync(binaryFile));
}

function instantiateArrayBuffer(binaryFile, imports, receiver) {
  return getBinaryPromise(binaryFile).then(binary => WebAssembly.instantiate(binary, imports)).then(receiver, reason => {
    err(`failed to asynchronously prepare wasm: ${reason}`);
    abort(reason);
  });
}

function instantiateAsync(binary, binaryFile, imports, callback) {
  if (!binary && typeof WebAssembly.instantiateStreaming == "function" && !isDataURI(binaryFile) && // Don't use streaming for file:// delivered objects in a webview, fetch them synchronously.
  !isFileURI(binaryFile) && // Avoid instantiateStreaming() on Node.js environment for now, as while
  // Node.js v18.1.0 implements it, it does not have a full fetch()
  // implementation yet.
  // Reference:
  //   https://github.com/emscripten-core/emscripten/pull/16917
  !ENVIRONMENT_IS_NODE && typeof fetch == "function") {
    return fetch(binaryFile, {
      credentials: "same-origin"
    }).then(response => {
      // Suppress closure warning here since the upstream definition for
      // instantiateStreaming only allows Promise<Repsponse> rather than
      // an actual Response.
      // TODO(https://github.com/google/closure-compiler/pull/3913): Remove if/when upstream closure is fixed.
      /** @suppress {checkTypes} */ var result = WebAssembly.instantiateStreaming(response, imports);
      return result.then(callback, function(reason) {
        // We expect the most common failure cause to be a bad MIME type for the binary,
        // in which case falling back to ArrayBuffer instantiation should work.
        err(`wasm streaming compile failed: ${reason}`);
        err("falling back to ArrayBuffer instantiation");
        return instantiateArrayBuffer(binaryFile, imports, callback);
      });
    });
  }
  return instantiateArrayBuffer(binaryFile, imports, callback);
}

function getWasmImports() {
  assignWasmImports();
  // prepare imports
  return {
    "env": wasmImports,
    "wasi_snapshot_preview1": wasmImports
  };
}

// Create the wasm instance.
// Receives the wasm imports, returns the exports.
function createWasm() {
  // Load the wasm module and create an instance of using native support in the JS engine.
  // handle a generated wasm instance, receiving its exports and
  // performing other necessary setup
  /** @param {WebAssembly.Module=} module*/ function receiveInstance(instance, module) {
    wasmExports = instance.exports;
    registerTLSInit(wasmExports["_emscripten_tls_init"]);
    wasmTable = wasmExports["__indirect_function_table"];
    addOnInit(wasmExports["__wasm_call_ctors"]);
    // We now have the Wasm module loaded up, keep a reference to the compiled module so we can post it to the workers.
    wasmModule = module;
    removeRunDependency("wasm-instantiate");
    return wasmExports;
  }
  // wait for the pthread pool (if any)
  addRunDependency("wasm-instantiate");
  // Prefer streaming instantiation if available.
  function receiveInstantiationResult(result) {
    // 'result' is a ResultObject object which has both the module and instance.
    // receiveInstance() will swap in the exports (to Module.asm) so they can be called
    receiveInstance(result["instance"], result["module"]);
  }
  var info = getWasmImports();
  // User shell pages can write their own Module.instantiateWasm = function(imports, successCallback) callback
  // to manually instantiate the Wasm module themselves. This allows pages to
  // run the instantiation parallel to any other async startup actions they are
  // performing.
  // Also pthreads and wasm workers initialize the wasm instance through this
  // path.
  if (Module["instantiateWasm"]) {
    try {
      return Module["instantiateWasm"](info, receiveInstance);
    } catch (e) {
      err(`Module.instantiateWasm callback failed with error: ${e}`);
      // If instantiation fails, reject the module ready promise.
      readyPromiseReject(e);
    }
  }
  if (ENVIRONMENT_IS_PTHREAD) {
    return new Promise(resolve => {
      wasmModuleReceived = module => {
        // Instantiate from the module posted from the main thread.
        // We can just use sync instantiation in the worker.
        var instance = new WebAssembly.Instance(module, getWasmImports());
        receiveInstance(instance, module);
        resolve();
      };
    });
  }
  wasmBinaryFile ??= findWasmBinary();
  // If instantiation fails, reject the module ready promise.
  instantiateAsync(wasmBinary, wasmBinaryFile, info, receiveInstantiationResult).catch(readyPromiseReject);
  return {};
}

// Globals used by JS i64 conversions (see makeSetValue)
var tempDouble;

var tempI64;

// include: runtime_debug.js
// end include: runtime_debug.js
// === Body ===
// end include: preamble.js
class ExitStatus {
  name="ExitStatus";
  constructor(status) {
    this.message = `Program terminated with exit(${status})`;
    this.status = status;
  }
}

var terminateWorker = worker => {
  worker.terminate();
  // terminate() can be asynchronous, so in theory the worker can continue
  // to run for some amount of time after termination.  However from our POV
  // the worker now dead and we don't want to hear from it again, so we stub
  // out its message handler here.  This avoids having to check in each of
  // the onmessage handlers if the message was coming from valid worker.
  worker.onmessage = e => {};
};

var cleanupThread = pthread_ptr => {
  var worker = PThread.pthreads[pthread_ptr];
  PThread.returnWorkerToPool(worker);
};

var spawnThread = threadParams => {
  var worker = PThread.getNewWorker();
  if (!worker) {
    // No available workers in the PThread pool.
    return 6;
  }
  PThread.runningWorkers.push(worker);
  // Add to pthreads map
  PThread.pthreads[threadParams.pthread_ptr] = worker;
  worker.pthread_ptr = threadParams.pthread_ptr;
  var msg = {
    cmd: "run",
    start_routine: threadParams.startRoutine,
    arg: threadParams.arg,
    pthread_ptr: threadParams.pthread_ptr
  };
  if (ENVIRONMENT_IS_NODE) {
    // Mark worker as weakly referenced once we start executing a pthread,
    // so that its existence does not prevent Node.js from exiting.  This
    // has no effect if the worker is already weakly referenced (e.g. if
    // this worker was previously idle/unused).
    worker.unref();
  }
  // Ask the worker to start executing its pthread entry point function.
  worker.postMessage(msg, threadParams.transferList);
  return 0;
};

var runtimeKeepaliveCounter = 0;

var keepRuntimeAlive = () => noExitRuntime || runtimeKeepaliveCounter > 0;

var stackSave = () => _emscripten_stack_get_current();

var stackRestore = val => __emscripten_stack_restore(val);

var stackAlloc = sz => __emscripten_stack_alloc(sz);

var convertI32PairToI53Checked = (lo, hi) => ((hi + 2097152) >>> 0 < 4194305 - !!lo) ? (lo >>> 0) + hi * 4294967296 : NaN;

/** @type{function(number, (number|boolean), ...number)} */ var proxyToMainThread = (funcIndex, emAsmAddr, sync, ...callArgs) => {
  // EM_ASM proxying is done by passing a pointer to the address of the EM_ASM
  // content as `emAsmAddr`.  JS library proxying is done by passing an index
  // into `proxiedJSCallArgs` as `funcIndex`. If `emAsmAddr` is non-zero then
  // `funcIndex` will be ignored.
  // Additional arguments are passed after the first three are the actual
  // function arguments.
  // The serialization buffer contains the number of call params, and then
  // all the args here.
  // We also pass 'sync' to C separately, since C needs to look at it.
  // Allocate a buffer, which will be copied by the C code.
  // First passed parameter specifies the number of arguments to the function.
  // When BigInt support is enabled, we must handle types in a more complex
  // way, detecting at runtime if a value is a BigInt or not (as we have no
  // type info here). To do that, add a "prefix" before each value that
  // indicates if it is a BigInt, which effectively doubles the number of
  // values we serialize for proxying. TODO: pack this?
  var serializedNumCallArgs = callArgs.length;
  var sp = stackSave();
  var args = stackAlloc(serializedNumCallArgs * 8);
  var b = ((args) >> 3);
  for (var i = 0; i < callArgs.length; i++) {
    var arg = callArgs[i];
    GROWABLE_HEAP_F64()[b + i] = arg;
  }
  var rtn = __emscripten_run_on_main_thread_js(funcIndex, emAsmAddr, serializedNumCallArgs, args, sync);
  stackRestore(sp);
  return rtn;
};

function _proc_exit(code) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(0, 0, 1, code);
  EXITSTATUS = code;
  if (!keepRuntimeAlive()) {
    PThread.terminateAllThreads();
    Module["onExit"]?.(code);
    ABORT = true;
  }
  quit_(code, new ExitStatus(code));
}

var handleException = e => {
  // Certain exception types we do not treat as errors since they are used for
  // internal control flow.
  // 1. ExitStatus, which is thrown by exit()
  // 2. "unwind", which is thrown by emscripten_unwind_to_js_event_loop() and others
  //    that wish to return to JS event loop.
  if (e instanceof ExitStatus || e == "unwind") {
    return EXITSTATUS;
  }
  quit_(1, e);
};

function exitOnMainThread(returnCode) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(1, 0, 0, returnCode);
  _exit(returnCode);
}

/** @suppress {duplicate } */ /** @param {boolean|number=} implicit */ var exitJS = (status, implicit) => {
  EXITSTATUS = status;
  if (ENVIRONMENT_IS_PTHREAD) {
    // implicit exit can never happen on a pthread
    // When running in a pthread we propagate the exit back to the main thread
    // where it can decide if the whole process should be shut down or not.
    // The pthread may have decided not to exit its own runtime, for example
    // because it runs a main loop, but that doesn't affect the main thread.
    exitOnMainThread(status);
    throw "unwind";
  }
  _proc_exit(status);
};

var _exit = exitJS;

var PThread = {
  unusedWorkers: [],
  runningWorkers: [],
  tlsInitFunctions: [],
  pthreads: {},
  init() {
    if ((!(ENVIRONMENT_IS_PTHREAD))) {
      PThread.initMainThread();
    }
  },
  initMainThread() {
    // MINIMAL_RUNTIME takes care of calling loadWasmModuleToAllWorkers
    // in postamble_minimal.js
    addOnPreRun(() => {
      addRunDependency("loading-workers");
      PThread.loadWasmModuleToAllWorkers(() => removeRunDependency("loading-workers"));
    });
  },
  terminateAllThreads: () => {
    // Attempt to kill all workers.  Sadly (at least on the web) there is no
    // way to terminate a worker synchronously, or to be notified when a
    // worker in actually terminated.  This means there is some risk that
    // pthreads will continue to be executing after `worker.terminate` has
    // returned.  For this reason, we don't call `returnWorkerToPool` here or
    // free the underlying pthread data structures.
    for (var worker of PThread.runningWorkers) {
      terminateWorker(worker);
    }
    for (var worker of PThread.unusedWorkers) {
      terminateWorker(worker);
    }
    PThread.unusedWorkers = [];
    PThread.runningWorkers = [];
    PThread.pthreads = {};
  },
  returnWorkerToPool: worker => {
    // We don't want to run main thread queued calls here, since we are doing
    // some operations that leave the worker queue in an invalid state until
    // we are completely done (it would be bad if free() ends up calling a
    // queued pthread_create which looks at the global data structures we are
    // modifying). To achieve that, defer the free() til the very end, when
    // we are all done.
    var pthread_ptr = worker.pthread_ptr;
    delete PThread.pthreads[pthread_ptr];
    // Note: worker is intentionally not terminated so the pool can
    // dynamically grow.
    PThread.unusedWorkers.push(worker);
    PThread.runningWorkers.splice(PThread.runningWorkers.indexOf(worker), 1);
    // Not a running Worker anymore
    // Detach the worker from the pthread object, and return it to the
    // worker pool as an unused worker.
    worker.pthread_ptr = 0;
    // Finally, free the underlying (and now-unused) pthread structure in
    // linear memory.
    __emscripten_thread_free_data(pthread_ptr);
  },
  receiveObjectTransfer(data) {},
  threadInitTLS() {
    // Call thread init functions (these are the _emscripten_tls_init for each
    // module loaded.
    PThread.tlsInitFunctions.forEach(f => f());
  },
  loadWasmModuleToWorker: worker => new Promise(onFinishedLoading => {
    worker.onmessage = e => {
      var d = e["data"];
      var cmd = d.cmd;
      // If this message is intended to a recipient that is not the main
      // thread, forward it to the target thread.
      if (d.targetThread && d.targetThread != _pthread_self()) {
        var targetWorker = PThread.pthreads[d.targetThread];
        if (targetWorker) {
          targetWorker.postMessage(d, d.transferList);
        } else {
          err(`Internal error! Worker sent a message "${cmd}" to target pthread ${d.targetThread}, but that thread no longer exists!`);
        }
        return;
      }
      if (cmd === "checkMailbox") {
        checkMailbox();
      } else if (cmd === "spawnThread") {
        spawnThread(d);
      } else if (cmd === "cleanupThread") {
        cleanupThread(d.thread);
      } else if (cmd === "loaded") {
        worker.loaded = true;
        onFinishedLoading(worker);
      } else if (cmd === "alert") {
        alert(`Thread ${d.threadId}: ${d.text}`);
      } else if (d.target === "setimmediate") {
        // Worker wants to postMessage() to itself to implement setImmediate()
        // emulation.
        worker.postMessage(d);
      } else if (cmd === "callHandler") {
        Module[d.handler](...d.args);
      } else if (cmd) {
        // The received message looks like something that should be handled by this message
        // handler, (since there is a e.data.cmd field present), but is not one of the
        // recognized commands:
        err(`worker sent an unknown command ${cmd}`);
      }
    };
    worker.onerror = e => {
      var message = "worker sent an error!";
      err(`${message} ${e.filename}:${e.lineno}: ${e.message}`);
      throw e;
    };
    if (ENVIRONMENT_IS_NODE) {
      worker.on("message", data => worker.onmessage({
        data
      }));
      worker.on("error", e => worker.onerror(e));
    }
    // When running on a pthread, none of the incoming parameters on the module
    // object are present. Proxy known handlers back to the main thread if specified.
    var handlers = [];
    var knownHandlers = [ "onExit", "onAbort", "print", "printErr" ];
    for (var handler of knownHandlers) {
      if (Module.propertyIsEnumerable(handler)) {
        handlers.push(handler);
      }
    }
    // Ask the new worker to load up the Emscripten-compiled page. This is a heavy operation.
    worker.postMessage({
      cmd: "load",
      handlers,
      wasmMemory,
      wasmModule
    });
  }),
  loadWasmModuleToAllWorkers(onMaybeReady) {
    onMaybeReady();
  },
  allocateUnusedWorker() {
    var worker;
    var workerOptions = {
      "type": "module",
      // This is the way that we signal to the node worker that it is hosting
      // a pthread.
      "workerData": "em-pthread",
      // This is the way that we signal to the Web Worker that it is hosting
      // a pthread.
      "name": "em-pthread"
    };
    // If we're using module output, use bundler-friendly pattern.
    // We need to generate the URL with import.meta.url as the base URL of the JS file
    // instead of just using new URL(import.meta.url) because bundler's only recognize
    // the first case in their bundling step. The latter ends up producing an invalid
    // URL to import from the server (e.g., for webpack the file:// path).
    worker = new Worker(new URL("verifproxy_wasm.js", import.meta.url), workerOptions);
    PThread.unusedWorkers.push(worker);
  },
  getNewWorker() {
    if (PThread.unusedWorkers.length == 0) {
      // PTHREAD_POOL_SIZE_STRICT should show a warning and, if set to level `2`, return from the function.
      PThread.allocateUnusedWorker();
      PThread.loadWasmModuleToWorker(PThread.unusedWorkers[0]);
    }
    return PThread.unusedWorkers.pop();
  }
};

var callRuntimeCallbacks = callbacks => {
  while (callbacks.length > 0) {
    // Pass the module as the first argument.
    callbacks.shift()(Module);
  }
};

var establishStackSpace = pthread_ptr => {
  // If memory growth is enabled, the memory views may have gotten out of date,
  // so resync them before accessing the pthread ptr below.
  updateMemoryViews();
  var stackHigh = GROWABLE_HEAP_U32()[(((pthread_ptr) + (52)) >> 2)];
  var stackSize = GROWABLE_HEAP_U32()[(((pthread_ptr) + (56)) >> 2)];
  var stackLow = stackHigh - stackSize;
  // Set stack limits used by `emscripten/stack.h` function.  These limits are
  // cached in wasm-side globals to make checks as fast as possible.
  _emscripten_stack_set_limits(stackHigh, stackLow);
  // Call inside wasm module to set up the stack frame for this pthread in wasm module scope
  stackRestore(stackHigh);
};

/**
     * @param {number} ptr
     * @param {string} type
     */ function getValue(ptr, type = "i8") {
  if (type.endsWith("*")) type = "*";
  switch (type) {
   case "i1":
    return GROWABLE_HEAP_I8()[ptr];

   case "i8":
    return GROWABLE_HEAP_I8()[ptr];

   case "i16":
    return GROWABLE_HEAP_I16()[((ptr) >> 1)];

   case "i32":
    return GROWABLE_HEAP_I32()[((ptr) >> 2)];

   case "i64":
    abort("to do getValue(i64) use WASM_BIGINT");

   case "float":
    return GROWABLE_HEAP_F32()[((ptr) >> 2)];

   case "double":
    return GROWABLE_HEAP_F64()[((ptr) >> 3)];

   case "*":
    return GROWABLE_HEAP_U32()[((ptr) >> 2)];

   default:
    abort(`invalid type for getValue: ${type}`);
  }
}

var wasmTableMirror = [];

/** @type {WebAssembly.Table} */ var wasmTable;

var getWasmTableEntry = funcPtr => {
  var func = wasmTableMirror[funcPtr];
  if (!func) {
    if (funcPtr >= wasmTableMirror.length) wasmTableMirror.length = funcPtr + 1;
    /** @suppress {checkTypes} */ wasmTableMirror[funcPtr] = func = wasmTable.get(funcPtr);
  }
  return func;
};

var invokeEntryPoint = (ptr, arg) => {
  // An old thread on this worker may have been canceled without returning the
  // `runtimeKeepaliveCounter` to zero. Reset it now so the new thread won't
  // be affected.
  runtimeKeepaliveCounter = 0;
  // Same for noExitRuntime.  The default for pthreads should always be false
  // otherwise pthreads would never complete and attempts to pthread_join to
  // them would block forever.
  // pthreads can still choose to set `noExitRuntime` explicitly, or
  // call emscripten_unwind_to_js_event_loop to extend their lifetime beyond
  // their main function.  See comment in src/runtime_pthread.js for more.
  noExitRuntime = 0;
  // pthread entry points are always of signature 'void *ThreadMain(void *arg)'
  // Native codebases sometimes spawn threads with other thread entry point
  // signatures, such as void ThreadMain(void *arg), void *ThreadMain(), or
  // void ThreadMain().  That is not acceptable per C/C++ specification, but
  // x86 compiler ABI extensions enable that to work. If you find the
  // following line to crash, either change the signature to "proper" void
  // *ThreadMain(void *arg) form, or try linking with the Emscripten linker
  // flag -sEMULATE_FUNCTION_POINTER_CASTS to add in emulation for this x86
  // ABI extension.
  var result = getWasmTableEntry(ptr)(arg);
  function finish(result) {
    if (keepRuntimeAlive()) {
      EXITSTATUS = result;
    } else {
      __emscripten_thread_exit(result);
    }
  }
  finish(result);
};

var noExitRuntime = Module["noExitRuntime"] || true;

var registerTLSInit = tlsInitFunc => PThread.tlsInitFunctions.push(tlsInitFunc);

/**
     * @param {number} ptr
     * @param {number} value
     * @param {string} type
     */ function setValue(ptr, value, type = "i8") {
  if (type.endsWith("*")) type = "*";
  switch (type) {
   case "i1":
    GROWABLE_HEAP_I8()[ptr] = value;
    break;

   case "i8":
    GROWABLE_HEAP_I8()[ptr] = value;
    break;

   case "i16":
    GROWABLE_HEAP_I16()[((ptr) >> 1)] = value;
    break;

   case "i32":
    GROWABLE_HEAP_I32()[((ptr) >> 2)] = value;
    break;

   case "i64":
    abort("to do setValue(i64) use WASM_BIGINT");

   case "float":
    GROWABLE_HEAP_F32()[((ptr) >> 2)] = value;
    break;

   case "double":
    GROWABLE_HEAP_F64()[((ptr) >> 3)] = value;
    break;

   case "*":
    GROWABLE_HEAP_U32()[((ptr) >> 2)] = value;
    break;

   default:
    abort(`invalid type for setValue: ${type}`);
  }
}

var UTF8Decoder = typeof TextDecoder != "undefined" ? new TextDecoder : undefined;

/**
     * Given a pointer 'idx' to a null-terminated UTF8-encoded string in the given
     * array that contains uint8 values, returns a copy of that string as a
     * Javascript String object.
     * heapOrArray is either a regular array, or a JavaScript typed array view.
     * @param {number=} idx
     * @param {number=} maxBytesToRead
     * @return {string}
     */ var UTF8ArrayToString = (heapOrArray, idx = 0, maxBytesToRead = NaN) => {
  var endIdx = idx + maxBytesToRead;
  var endPtr = idx;
  // TextDecoder needs to know the byte length in advance, it doesn't stop on
  // null terminator by itself.  Also, use the length info to avoid running tiny
  // strings through TextDecoder, since .subarray() allocates garbage.
  // (As a tiny code save trick, compare endPtr against endIdx using a negation,
  // so that undefined/NaN means Infinity)
  while (heapOrArray[endPtr] && !(endPtr >= endIdx)) ++endPtr;
  if (endPtr - idx > 16 && heapOrArray.buffer && UTF8Decoder) {
    return UTF8Decoder.decode(heapOrArray.buffer instanceof ArrayBuffer ? heapOrArray.subarray(idx, endPtr) : heapOrArray.slice(idx, endPtr));
  }
  var str = "";
  // If building with TextDecoder, we have already computed the string length
  // above, so test loop end condition against that
  while (idx < endPtr) {
    // For UTF8 byte structure, see:
    // http://en.wikipedia.org/wiki/UTF-8#Description
    // https://www.ietf.org/rfc/rfc2279.txt
    // https://tools.ietf.org/html/rfc3629
    var u0 = heapOrArray[idx++];
    if (!(u0 & 128)) {
      str += String.fromCharCode(u0);
      continue;
    }
    var u1 = heapOrArray[idx++] & 63;
    if ((u0 & 224) == 192) {
      str += String.fromCharCode(((u0 & 31) << 6) | u1);
      continue;
    }
    var u2 = heapOrArray[idx++] & 63;
    if ((u0 & 240) == 224) {
      u0 = ((u0 & 15) << 12) | (u1 << 6) | u2;
    } else {
      u0 = ((u0 & 7) << 18) | (u1 << 12) | (u2 << 6) | (heapOrArray[idx++] & 63);
    }
    if (u0 < 65536) {
      str += String.fromCharCode(u0);
    } else {
      var ch = u0 - 65536;
      str += String.fromCharCode(55296 | (ch >> 10), 56320 | (ch & 1023));
    }
  }
  return str;
};

/**
     * Given a pointer 'ptr' to a null-terminated UTF8-encoded string in the
     * emscripten HEAP, returns a copy of that string as a Javascript String object.
     *
     * @param {number} ptr
     * @param {number=} maxBytesToRead - An optional length that specifies the
     *   maximum number of bytes to read. You can omit this parameter to scan the
     *   string until the first 0 byte. If maxBytesToRead is passed, and the string
     *   at [ptr, ptr+maxBytesToReadr[ contains a null byte in the middle, then the
     *   string will cut short at that byte index (i.e. maxBytesToRead will not
     *   produce a string of exact length [ptr, ptr+maxBytesToRead[) N.B. mixing
     *   frequent uses of UTF8ToString() with and without maxBytesToRead may throw
     *   JS JIT optimizations off, so it is worth to consider consistently using one
     * @return {string}
     */ var UTF8ToString = (ptr, maxBytesToRead) => ptr ? UTF8ArrayToString(GROWABLE_HEAP_U8(), ptr, maxBytesToRead) : "";

var ___assert_fail = (condition, filename, line, func) => abort(`Assertion failed: ${UTF8ToString(condition)}, at: ` + [ filename ? UTF8ToString(filename) : "unknown filename", line, func ? UTF8ToString(func) : "unknown function" ]);

var ___call_sighandler = (fp, sig) => getWasmTableEntry(fp)(sig);

var initRandomFill = () => {
  if (typeof crypto == "object" && typeof crypto["getRandomValues"] == "function") {
    // for modern web browsers
    // like with most Web APIs, we can't use Web Crypto API directly on shared memory,
    // so we need to create an intermediate buffer and copy it to the destination
    return view => (view.set(crypto.getRandomValues(new Uint8Array(view.byteLength))), 
    // Return the original view to match modern native implementations.
    view);
  } else if (ENVIRONMENT_IS_NODE) {
    // for nodejs with or without crypto support included
    try {
      var crypto_module = require("crypto");
      var randomFillSync = crypto_module["randomFillSync"];
      if (randomFillSync) {
        // nodejs with LTS crypto support
        return view => crypto_module["randomFillSync"](view);
      }
      // very old nodejs with the original crypto API
      var randomBytes = crypto_module["randomBytes"];
      return view => (view.set(randomBytes(view.byteLength)), // Return the original view to match modern native implementations.
      view);
    } catch (e) {}
  }
  // we couldn't find a proper implementation, as Math.random() is not suitable for /dev/random, see emscripten-core/emscripten/pull/7096
  abort("initRandomDevice");
};

var randomFill = view => (randomFill = initRandomFill())(view);

var PATH = {
  isAbs: path => path.charAt(0) === "/",
  splitPath: filename => {
    var splitPathRe = /^(\/?|)([\s\S]*?)((?:\.{1,2}|[^\/]+?|)(\.[^.\/]*|))(?:[\/]*)$/;
    return splitPathRe.exec(filename).slice(1);
  },
  normalizeArray: (parts, allowAboveRoot) => {
    // if the path tries to go above the root, `up` ends up > 0
    var up = 0;
    for (var i = parts.length - 1; i >= 0; i--) {
      var last = parts[i];
      if (last === ".") {
        parts.splice(i, 1);
      } else if (last === "..") {
        parts.splice(i, 1);
        up++;
      } else if (up) {
        parts.splice(i, 1);
        up--;
      }
    }
    // if the path is allowed to go above the root, restore leading ..s
    if (allowAboveRoot) {
      for (;up; up--) {
        parts.unshift("..");
      }
    }
    return parts;
  },
  normalize: path => {
    var isAbsolute = PATH.isAbs(path), trailingSlash = path.substr(-1) === "/";
    // Normalize the path
    path = PATH.normalizeArray(path.split("/").filter(p => !!p), !isAbsolute).join("/");
    if (!path && !isAbsolute) {
      path = ".";
    }
    if (path && trailingSlash) {
      path += "/";
    }
    return (isAbsolute ? "/" : "") + path;
  },
  dirname: path => {
    var result = PATH.splitPath(path), root = result[0], dir = result[1];
    if (!root && !dir) {
      // No dirname whatsoever
      return ".";
    }
    if (dir) {
      // It has a dirname, strip trailing slash
      dir = dir.substr(0, dir.length - 1);
    }
    return root + dir;
  },
  basename: path => {
    // EMSCRIPTEN return '/'' for '/', not an empty string
    if (path === "/") return "/";
    path = PATH.normalize(path);
    path = path.replace(/\/$/, "");
    var lastSlash = path.lastIndexOf("/");
    if (lastSlash === -1) return path;
    return path.substr(lastSlash + 1);
  },
  join: (...paths) => PATH.normalize(paths.join("/")),
  join2: (l, r) => PATH.normalize(l + "/" + r)
};

var PATH_FS = {
  resolve: (...args) => {
    var resolvedPath = "", resolvedAbsolute = false;
    for (var i = args.length - 1; i >= -1 && !resolvedAbsolute; i--) {
      var path = (i >= 0) ? args[i] : FS.cwd();
      // Skip empty and invalid entries
      if (typeof path != "string") {
        throw new TypeError("Arguments to path.resolve must be strings");
      } else if (!path) {
        return "";
      }
      // an invalid portion invalidates the whole thing
      resolvedPath = path + "/" + resolvedPath;
      resolvedAbsolute = PATH.isAbs(path);
    }
    // At this point the path should be resolved to a full absolute path, but
    // handle relative paths to be safe (might happen when process.cwd() fails)
    resolvedPath = PATH.normalizeArray(resolvedPath.split("/").filter(p => !!p), !resolvedAbsolute).join("/");
    return ((resolvedAbsolute ? "/" : "") + resolvedPath) || ".";
  },
  relative: (from, to) => {
    from = PATH_FS.resolve(from).substr(1);
    to = PATH_FS.resolve(to).substr(1);
    function trim(arr) {
      var start = 0;
      for (;start < arr.length; start++) {
        if (arr[start] !== "") break;
      }
      var end = arr.length - 1;
      for (;end >= 0; end--) {
        if (arr[end] !== "") break;
      }
      if (start > end) return [];
      return arr.slice(start, end - start + 1);
    }
    var fromParts = trim(from.split("/"));
    var toParts = trim(to.split("/"));
    var length = Math.min(fromParts.length, toParts.length);
    var samePartsLength = length;
    for (var i = 0; i < length; i++) {
      if (fromParts[i] !== toParts[i]) {
        samePartsLength = i;
        break;
      }
    }
    var outputParts = [];
    for (var i = samePartsLength; i < fromParts.length; i++) {
      outputParts.push("..");
    }
    outputParts = outputParts.concat(toParts.slice(samePartsLength));
    return outputParts.join("/");
  }
};

var FS_stdin_getChar_buffer = [];

var lengthBytesUTF8 = str => {
  var len = 0;
  for (var i = 0; i < str.length; ++i) {
    // Gotcha: charCodeAt returns a 16-bit word that is a UTF-16 encoded code
    // unit, not a Unicode code point of the character! So decode
    // UTF16->UTF32->UTF8.
    // See http://unicode.org/faq/utf_bom.html#utf16-3
    var c = str.charCodeAt(i);
    // possibly a lead surrogate
    if (c <= 127) {
      len++;
    } else if (c <= 2047) {
      len += 2;
    } else if (c >= 55296 && c <= 57343) {
      len += 4;
      ++i;
    } else {
      len += 3;
    }
  }
  return len;
};

var stringToUTF8Array = (str, heap, outIdx, maxBytesToWrite) => {
  // Parameter maxBytesToWrite is not optional. Negative values, 0, null,
  // undefined and false each don't write out any bytes.
  if (!(maxBytesToWrite > 0)) return 0;
  var startIdx = outIdx;
  var endIdx = outIdx + maxBytesToWrite - 1;
  // -1 for string null terminator.
  for (var i = 0; i < str.length; ++i) {
    // Gotcha: charCodeAt returns a 16-bit word that is a UTF-16 encoded code
    // unit, not a Unicode code point of the character! So decode
    // UTF16->UTF32->UTF8.
    // See http://unicode.org/faq/utf_bom.html#utf16-3
    // For UTF8 byte structure, see http://en.wikipedia.org/wiki/UTF-8#Description
    // and https://www.ietf.org/rfc/rfc2279.txt
    // and https://tools.ietf.org/html/rfc3629
    var u = str.charCodeAt(i);
    // possibly a lead surrogate
    if (u >= 55296 && u <= 57343) {
      var u1 = str.charCodeAt(++i);
      u = 65536 + ((u & 1023) << 10) | (u1 & 1023);
    }
    if (u <= 127) {
      if (outIdx >= endIdx) break;
      heap[outIdx++] = u;
    } else if (u <= 2047) {
      if (outIdx + 1 >= endIdx) break;
      heap[outIdx++] = 192 | (u >> 6);
      heap[outIdx++] = 128 | (u & 63);
    } else if (u <= 65535) {
      if (outIdx + 2 >= endIdx) break;
      heap[outIdx++] = 224 | (u >> 12);
      heap[outIdx++] = 128 | ((u >> 6) & 63);
      heap[outIdx++] = 128 | (u & 63);
    } else {
      if (outIdx + 3 >= endIdx) break;
      heap[outIdx++] = 240 | (u >> 18);
      heap[outIdx++] = 128 | ((u >> 12) & 63);
      heap[outIdx++] = 128 | ((u >> 6) & 63);
      heap[outIdx++] = 128 | (u & 63);
    }
  }
  // Null-terminate the pointer to the buffer.
  heap[outIdx] = 0;
  return outIdx - startIdx;
};

/** @type {function(string, boolean=, number=)} */ function intArrayFromString(stringy, dontAddNull, length) {
  var len = length > 0 ? length : lengthBytesUTF8(stringy) + 1;
  var u8array = new Array(len);
  var numBytesWritten = stringToUTF8Array(stringy, u8array, 0, u8array.length);
  if (dontAddNull) u8array.length = numBytesWritten;
  return u8array;
}

var FS_stdin_getChar = () => {
  if (!FS_stdin_getChar_buffer.length) {
    var result = null;
    if (ENVIRONMENT_IS_NODE) {
      // we will read data by chunks of BUFSIZE
      var BUFSIZE = 256;
      var buf = Buffer.alloc(BUFSIZE);
      var bytesRead = 0;
      // For some reason we must suppress a closure warning here, even though
      // fd definitely exists on process.stdin, and is even the proper way to
      // get the fd of stdin,
      // https://github.com/nodejs/help/issues/2136#issuecomment-523649904
      // This started to happen after moving this logic out of library_tty.js,
      // so it is related to the surrounding code in some unclear manner.
      /** @suppress {missingProperties} */ var fd = process.stdin.fd;
      try {
        bytesRead = fs.readSync(fd, buf, 0, BUFSIZE);
      } catch (e) {
        // Cross-platform differences: on Windows, reading EOF throws an
        // exception, but on other OSes, reading EOF returns 0. Uniformize
        // behavior by treating the EOF exception to return 0.
        if (e.toString().includes("EOF")) bytesRead = 0; else throw e;
      }
      if (bytesRead > 0) {
        result = buf.slice(0, bytesRead).toString("utf-8");
      }
    } else if (typeof window != "undefined" && typeof window.prompt == "function") {
      // Browser.
      result = window.prompt("Input: ");
      // returns null on cancel
      if (result !== null) {
        result += "\n";
      }
    } else {}
    if (!result) {
      return null;
    }
    FS_stdin_getChar_buffer = intArrayFromString(result, true);
  }
  return FS_stdin_getChar_buffer.shift();
};

var TTY = {
  ttys: [],
  init() {},
  // https://github.com/emscripten-core/emscripten/pull/1555
  // if (ENVIRONMENT_IS_NODE) {
  //   // currently, FS.init does not distinguish if process.stdin is a file or TTY
  //   // device, it always assumes it's a TTY device. because of this, we're forcing
  //   // process.stdin to UTF8 encoding to at least make stdin reading compatible
  //   // with text files until FS.init can be refactored.
  //   process.stdin.setEncoding('utf8');
  // }
  shutdown() {},
  // https://github.com/emscripten-core/emscripten/pull/1555
  // if (ENVIRONMENT_IS_NODE) {
  //   // inolen: any idea as to why node -e 'process.stdin.read()' wouldn't exit immediately (with process.stdin being a tty)?
  //   // isaacs: because now it's reading from the stream, you've expressed interest in it, so that read() kicks off a _read() which creates a ReadReq operation
  //   // inolen: I thought read() in that case was a synchronous operation that just grabbed some amount of buffered data if it exists?
  //   // isaacs: it is. but it also triggers a _read() call, which calls readStart() on the handle
  //   // isaacs: do process.stdin.pause() and i'd think it'd probably close the pending call
  //   process.stdin.pause();
  // }
  register(dev, ops) {
    TTY.ttys[dev] = {
      input: [],
      output: [],
      ops
    };
    FS.registerDevice(dev, TTY.stream_ops);
  },
  stream_ops: {
    open(stream) {
      var tty = TTY.ttys[stream.node.rdev];
      if (!tty) {
        throw new FS.ErrnoError(43);
      }
      stream.tty = tty;
      stream.seekable = false;
    },
    close(stream) {
      // flush any pending line data
      stream.tty.ops.fsync(stream.tty);
    },
    fsync(stream) {
      stream.tty.ops.fsync(stream.tty);
    },
    read(stream, buffer, offset, length, pos) {
      /* ignored */ if (!stream.tty || !stream.tty.ops.get_char) {
        throw new FS.ErrnoError(60);
      }
      var bytesRead = 0;
      for (var i = 0; i < length; i++) {
        var result;
        try {
          result = stream.tty.ops.get_char(stream.tty);
        } catch (e) {
          throw new FS.ErrnoError(29);
        }
        if (result === undefined && bytesRead === 0) {
          throw new FS.ErrnoError(6);
        }
        if (result === null || result === undefined) break;
        bytesRead++;
        buffer[offset + i] = result;
      }
      if (bytesRead) {
        stream.node.timestamp = Date.now();
      }
      return bytesRead;
    },
    write(stream, buffer, offset, length, pos) {
      if (!stream.tty || !stream.tty.ops.put_char) {
        throw new FS.ErrnoError(60);
      }
      try {
        for (var i = 0; i < length; i++) {
          stream.tty.ops.put_char(stream.tty, buffer[offset + i]);
        }
      } catch (e) {
        throw new FS.ErrnoError(29);
      }
      if (length) {
        stream.node.timestamp = Date.now();
      }
      return i;
    }
  },
  default_tty_ops: {
    get_char(tty) {
      return FS_stdin_getChar();
    },
    put_char(tty, val) {
      if (val === null || val === 10) {
        out(UTF8ArrayToString(tty.output));
        tty.output = [];
      } else {
        if (val != 0) tty.output.push(val);
      }
    },
    // val == 0 would cut text output off in the middle.
    fsync(tty) {
      if (tty.output && tty.output.length > 0) {
        out(UTF8ArrayToString(tty.output));
        tty.output = [];
      }
    },
    ioctl_tcgets(tty) {
      // typical setting
      return {
        c_iflag: 25856,
        c_oflag: 5,
        c_cflag: 191,
        c_lflag: 35387,
        c_cc: [ 3, 28, 127, 21, 4, 0, 1, 0, 17, 19, 26, 0, 18, 15, 23, 22, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ]
      };
    },
    ioctl_tcsets(tty, optional_actions, data) {
      // currently just ignore
      return 0;
    },
    ioctl_tiocgwinsz(tty) {
      return [ 24, 80 ];
    }
  },
  default_tty1_ops: {
    put_char(tty, val) {
      if (val === null || val === 10) {
        err(UTF8ArrayToString(tty.output));
        tty.output = [];
      } else {
        if (val != 0) tty.output.push(val);
      }
    },
    fsync(tty) {
      if (tty.output && tty.output.length > 0) {
        err(UTF8ArrayToString(tty.output));
        tty.output = [];
      }
    }
  }
};

var zeroMemory = (address, size) => {
  GROWABLE_HEAP_U8().fill(0, address, address + size);
};

var alignMemory = (size, alignment) => Math.ceil(size / alignment) * alignment;

var mmapAlloc = size => {
  size = alignMemory(size, 65536);
  var ptr = _emscripten_builtin_memalign(65536, size);
  if (ptr) zeroMemory(ptr, size);
  return ptr;
};

var MEMFS = {
  ops_table: null,
  mount(mount) {
    return MEMFS.createNode(null, "/", 16895, 0);
  },
  createNode(parent, name, mode, dev) {
    if (FS.isBlkdev(mode) || FS.isFIFO(mode)) {
      // no supported
      throw new FS.ErrnoError(63);
    }
    MEMFS.ops_table ||= {
      dir: {
        node: {
          getattr: MEMFS.node_ops.getattr,
          setattr: MEMFS.node_ops.setattr,
          lookup: MEMFS.node_ops.lookup,
          mknod: MEMFS.node_ops.mknod,
          rename: MEMFS.node_ops.rename,
          unlink: MEMFS.node_ops.unlink,
          rmdir: MEMFS.node_ops.rmdir,
          readdir: MEMFS.node_ops.readdir,
          symlink: MEMFS.node_ops.symlink
        },
        stream: {
          llseek: MEMFS.stream_ops.llseek
        }
      },
      file: {
        node: {
          getattr: MEMFS.node_ops.getattr,
          setattr: MEMFS.node_ops.setattr
        },
        stream: {
          llseek: MEMFS.stream_ops.llseek,
          read: MEMFS.stream_ops.read,
          write: MEMFS.stream_ops.write,
          allocate: MEMFS.stream_ops.allocate,
          mmap: MEMFS.stream_ops.mmap,
          msync: MEMFS.stream_ops.msync
        }
      },
      link: {
        node: {
          getattr: MEMFS.node_ops.getattr,
          setattr: MEMFS.node_ops.setattr,
          readlink: MEMFS.node_ops.readlink
        },
        stream: {}
      },
      chrdev: {
        node: {
          getattr: MEMFS.node_ops.getattr,
          setattr: MEMFS.node_ops.setattr
        },
        stream: FS.chrdev_stream_ops
      }
    };
    var node = FS.createNode(parent, name, mode, dev);
    if (FS.isDir(node.mode)) {
      node.node_ops = MEMFS.ops_table.dir.node;
      node.stream_ops = MEMFS.ops_table.dir.stream;
      node.contents = {};
    } else if (FS.isFile(node.mode)) {
      node.node_ops = MEMFS.ops_table.file.node;
      node.stream_ops = MEMFS.ops_table.file.stream;
      node.usedBytes = 0;
      // The actual number of bytes used in the typed array, as opposed to contents.length which gives the whole capacity.
      // When the byte data of the file is populated, this will point to either a typed array, or a normal JS array. Typed arrays are preferred
      // for performance, and used by default. However, typed arrays are not resizable like normal JS arrays are, so there is a small disk size
      // penalty involved for appending file writes that continuously grow a file similar to std::vector capacity vs used -scheme.
      node.contents = null;
    } else if (FS.isLink(node.mode)) {
      node.node_ops = MEMFS.ops_table.link.node;
      node.stream_ops = MEMFS.ops_table.link.stream;
    } else if (FS.isChrdev(node.mode)) {
      node.node_ops = MEMFS.ops_table.chrdev.node;
      node.stream_ops = MEMFS.ops_table.chrdev.stream;
    }
    node.timestamp = Date.now();
    // add the new node to the parent
    if (parent) {
      parent.contents[name] = node;
      parent.timestamp = node.timestamp;
    }
    return node;
  },
  getFileDataAsTypedArray(node) {
    if (!node.contents) return new Uint8Array(0);
    if (node.contents.subarray) return node.contents.subarray(0, node.usedBytes);
    // Make sure to not return excess unused bytes.
    return new Uint8Array(node.contents);
  },
  expandFileStorage(node, newCapacity) {
    var prevCapacity = node.contents ? node.contents.length : 0;
    if (prevCapacity >= newCapacity) return;
    // No need to expand, the storage was already large enough.
    // Don't expand strictly to the given requested limit if it's only a very small increase, but instead geometrically grow capacity.
    // For small filesizes (<1MB), perform size*2 geometric increase, but for large sizes, do a much more conservative size*1.125 increase to
    // avoid overshooting the allocation cap by a very large margin.
    var CAPACITY_DOUBLING_MAX = 1024 * 1024;
    newCapacity = Math.max(newCapacity, (prevCapacity * (prevCapacity < CAPACITY_DOUBLING_MAX ? 2 : 1.125)) >>> 0);
    if (prevCapacity != 0) newCapacity = Math.max(newCapacity, 256);
    // At minimum allocate 256b for each file when expanding.
    var oldContents = node.contents;
    node.contents = new Uint8Array(newCapacity);
    // Allocate new storage.
    if (node.usedBytes > 0) node.contents.set(oldContents.subarray(0, node.usedBytes), 0);
  },
  // Copy old data over to the new storage.
  resizeFileStorage(node, newSize) {
    if (node.usedBytes == newSize) return;
    if (newSize == 0) {
      node.contents = null;
      // Fully decommit when requesting a resize to zero.
      node.usedBytes = 0;
    } else {
      var oldContents = node.contents;
      node.contents = new Uint8Array(newSize);
      // Allocate new storage.
      if (oldContents) {
        node.contents.set(oldContents.subarray(0, Math.min(newSize, node.usedBytes)));
      }
      // Copy old data over to the new storage.
      node.usedBytes = newSize;
    }
  },
  node_ops: {
    getattr(node) {
      var attr = {};
      // device numbers reuse inode numbers.
      attr.dev = FS.isChrdev(node.mode) ? node.id : 1;
      attr.ino = node.id;
      attr.mode = node.mode;
      attr.nlink = 1;
      attr.uid = 0;
      attr.gid = 0;
      attr.rdev = node.rdev;
      if (FS.isDir(node.mode)) {
        attr.size = 4096;
      } else if (FS.isFile(node.mode)) {
        attr.size = node.usedBytes;
      } else if (FS.isLink(node.mode)) {
        attr.size = node.link.length;
      } else {
        attr.size = 0;
      }
      attr.atime = new Date(node.timestamp);
      attr.mtime = new Date(node.timestamp);
      attr.ctime = new Date(node.timestamp);
      // NOTE: In our implementation, st_blocks = Math.ceil(st_size/st_blksize),
      //       but this is not required by the standard.
      attr.blksize = 4096;
      attr.blocks = Math.ceil(attr.size / attr.blksize);
      return attr;
    },
    setattr(node, attr) {
      if (attr.mode !== undefined) {
        node.mode = attr.mode;
      }
      if (attr.timestamp !== undefined) {
        node.timestamp = attr.timestamp;
      }
      if (attr.size !== undefined) {
        MEMFS.resizeFileStorage(node, attr.size);
      }
    },
    lookup(parent, name) {
      throw MEMFS.doesNotExistError;
    },
    mknod(parent, name, mode, dev) {
      return MEMFS.createNode(parent, name, mode, dev);
    },
    rename(old_node, new_dir, new_name) {
      // if we're overwriting a directory at new_name, make sure it's empty.
      if (FS.isDir(old_node.mode)) {
        var new_node;
        try {
          new_node = FS.lookupNode(new_dir, new_name);
        } catch (e) {}
        if (new_node) {
          for (var i in new_node.contents) {
            throw new FS.ErrnoError(55);
          }
        }
      }
      // do the internal rewiring
      delete old_node.parent.contents[old_node.name];
      old_node.parent.timestamp = Date.now();
      old_node.name = new_name;
      new_dir.contents[new_name] = old_node;
      new_dir.timestamp = old_node.parent.timestamp;
    },
    unlink(parent, name) {
      delete parent.contents[name];
      parent.timestamp = Date.now();
    },
    rmdir(parent, name) {
      var node = FS.lookupNode(parent, name);
      for (var i in node.contents) {
        throw new FS.ErrnoError(55);
      }
      delete parent.contents[name];
      parent.timestamp = Date.now();
    },
    readdir(node) {
      var entries = [ ".", ".." ];
      for (var key of Object.keys(node.contents)) {
        entries.push(key);
      }
      return entries;
    },
    symlink(parent, newname, oldpath) {
      var node = MEMFS.createNode(parent, newname, 511 | 40960, 0);
      node.link = oldpath;
      return node;
    },
    readlink(node) {
      if (!FS.isLink(node.mode)) {
        throw new FS.ErrnoError(28);
      }
      return node.link;
    }
  },
  stream_ops: {
    read(stream, buffer, offset, length, position) {
      var contents = stream.node.contents;
      if (position >= stream.node.usedBytes) return 0;
      var size = Math.min(stream.node.usedBytes - position, length);
      if (size > 8 && contents.subarray) {
        // non-trivial, and typed array
        buffer.set(contents.subarray(position, position + size), offset);
      } else {
        for (var i = 0; i < size; i++) buffer[offset + i] = contents[position + i];
      }
      return size;
    },
    write(stream, buffer, offset, length, position, canOwn) {
      // If the buffer is located in main memory (HEAP), and if
      // memory can grow, we can't hold on to references of the
      // memory buffer, as they may get invalidated. That means we
      // need to do copy its contents.
      if (buffer.buffer === GROWABLE_HEAP_I8().buffer) {
        canOwn = false;
      }
      if (!length) return 0;
      var node = stream.node;
      node.timestamp = Date.now();
      if (buffer.subarray && (!node.contents || node.contents.subarray)) {
        // This write is from a typed array to a typed array?
        if (canOwn) {
          node.contents = buffer.subarray(offset, offset + length);
          node.usedBytes = length;
          return length;
        } else if (node.usedBytes === 0 && position === 0) {
          // If this is a simple first write to an empty file, do a fast set since we don't need to care about old data.
          node.contents = buffer.slice(offset, offset + length);
          node.usedBytes = length;
          return length;
        } else if (position + length <= node.usedBytes) {
          // Writing to an already allocated and used subrange of the file?
          node.contents.set(buffer.subarray(offset, offset + length), position);
          return length;
        }
      }
      // Appending to an existing file and we need to reallocate, or source data did not come as a typed array.
      MEMFS.expandFileStorage(node, position + length);
      if (node.contents.subarray && buffer.subarray) {
        // Use typed array write which is available.
        node.contents.set(buffer.subarray(offset, offset + length), position);
      } else {
        for (var i = 0; i < length; i++) {
          node.contents[position + i] = buffer[offset + i];
        }
      }
      node.usedBytes = Math.max(node.usedBytes, position + length);
      return length;
    },
    llseek(stream, offset, whence) {
      var position = offset;
      if (whence === 1) {
        position += stream.position;
      } else if (whence === 2) {
        if (FS.isFile(stream.node.mode)) {
          position += stream.node.usedBytes;
        }
      }
      if (position < 0) {
        throw new FS.ErrnoError(28);
      }
      return position;
    },
    allocate(stream, offset, length) {
      MEMFS.expandFileStorage(stream.node, offset + length);
      stream.node.usedBytes = Math.max(stream.node.usedBytes, offset + length);
    },
    mmap(stream, length, position, prot, flags) {
      if (!FS.isFile(stream.node.mode)) {
        throw new FS.ErrnoError(43);
      }
      var ptr;
      var allocated;
      var contents = stream.node.contents;
      // Only make a new copy when MAP_PRIVATE is specified.
      if (!(flags & 2) && contents && contents.buffer === GROWABLE_HEAP_I8().buffer) {
        // We can't emulate MAP_SHARED when the file is not backed by the
        // buffer we're mapping to (e.g. the HEAP buffer).
        allocated = false;
        ptr = contents.byteOffset;
      } else {
        allocated = true;
        ptr = mmapAlloc(length);
        if (!ptr) {
          throw new FS.ErrnoError(48);
        }
        if (contents) {
          // Try to avoid unnecessary slices.
          if (position > 0 || position + length < contents.length) {
            if (contents.subarray) {
              contents = contents.subarray(position, position + length);
            } else {
              contents = Array.prototype.slice.call(contents, position, position + length);
            }
          }
          GROWABLE_HEAP_I8().set(contents, ptr);
        }
      }
      return {
        ptr,
        allocated
      };
    },
    msync(stream, buffer, offset, length, mmapFlags) {
      MEMFS.stream_ops.write(stream, buffer, 0, length, offset, false);
      // should we check if bytesWritten and length are the same?
      return 0;
    }
  }
};

/** @param {boolean=} noRunDep */ var asyncLoad = (url, onload, onerror, noRunDep) => {
  var dep = !noRunDep ? getUniqueRunDependency(`al ${url}`) : "";
  readAsync(url).then(arrayBuffer => {
    onload(new Uint8Array(arrayBuffer));
    if (dep) removeRunDependency(dep);
  }, err => {
    if (onerror) {
      onerror();
    } else {
      throw `Loading data file "${url}" failed.`;
    }
  });
  if (dep) addRunDependency(dep);
};

var FS_createDataFile = (parent, name, fileData, canRead, canWrite, canOwn) => {
  FS.createDataFile(parent, name, fileData, canRead, canWrite, canOwn);
};

var preloadPlugins = Module["preloadPlugins"] || [];

var FS_handledByPreloadPlugin = (byteArray, fullname, finish, onerror) => {
  // Ensure plugins are ready.
  if (typeof Browser != "undefined") Browser.init();
  var handled = false;
  preloadPlugins.forEach(plugin => {
    if (handled) return;
    if (plugin["canHandle"](fullname)) {
      plugin["handle"](byteArray, fullname, finish, onerror);
      handled = true;
    }
  });
  return handled;
};

var FS_createPreloadedFile = (parent, name, url, canRead, canWrite, onload, onerror, dontCreateFile, canOwn, preFinish) => {
  // TODO we should allow people to just pass in a complete filename instead
  // of parent and name being that we just join them anyways
  var fullname = name ? PATH_FS.resolve(PATH.join2(parent, name)) : parent;
  var dep = getUniqueRunDependency(`cp ${fullname}`);
  // might have several active requests for the same fullname
  function processData(byteArray) {
    function finish(byteArray) {
      preFinish?.();
      if (!dontCreateFile) {
        FS_createDataFile(parent, name, byteArray, canRead, canWrite, canOwn);
      }
      onload?.();
      removeRunDependency(dep);
    }
    if (FS_handledByPreloadPlugin(byteArray, fullname, finish, () => {
      onerror?.();
      removeRunDependency(dep);
    })) {
      return;
    }
    finish(byteArray);
  }
  addRunDependency(dep);
  if (typeof url == "string") {
    asyncLoad(url, processData, onerror);
  } else {
    processData(url);
  }
};

var FS_modeStringToFlags = str => {
  var flagModes = {
    "r": 0,
    "r+": 2,
    "w": 512 | 64 | 1,
    "w+": 512 | 64 | 2,
    "a": 1024 | 64 | 1,
    "a+": 1024 | 64 | 2
  };
  var flags = flagModes[str];
  if (typeof flags == "undefined") {
    throw new Error(`Unknown file open mode: ${str}`);
  }
  return flags;
};

var FS_getMode = (canRead, canWrite) => {
  var mode = 0;
  if (canRead) mode |= 292 | 73;
  if (canWrite) mode |= 146;
  return mode;
};

var FS = {
  root: null,
  mounts: [],
  devices: {},
  streams: [],
  nextInode: 1,
  nameTable: null,
  currentPath: "/",
  initialized: false,
  ignorePermissions: true,
  ErrnoError: class {
    name="ErrnoError";
    // We set the `name` property to be able to identify `FS.ErrnoError`
    // - the `name` is a standard ECMA-262 property of error objects. Kind of good to have it anyway.
    // - when using PROXYFS, an error can come from an underlying FS
    // as different FS objects have their own FS.ErrnoError each,
    // the test `err instanceof FS.ErrnoError` won't detect an error coming from another filesystem, causing bugs.
    // we'll use the reliable test `err.name == "ErrnoError"` instead
    constructor(errno) {
      this.errno = errno;
    }
  },
  filesystems: null,
  syncFSRequests: 0,
  readFiles: {},
  FSStream: class {
    shared={};
    get object() {
      return this.node;
    }
    set object(val) {
      this.node = val;
    }
    get isRead() {
      return (this.flags & 2097155) !== 1;
    }
    get isWrite() {
      return (this.flags & 2097155) !== 0;
    }
    get isAppend() {
      return (this.flags & 1024);
    }
    get flags() {
      return this.shared.flags;
    }
    set flags(val) {
      this.shared.flags = val;
    }
    get position() {
      return this.shared.position;
    }
    set position(val) {
      this.shared.position = val;
    }
  },
  FSNode: class {
    node_ops={};
    stream_ops={};
    readMode=292 | 73;
    writeMode=146;
    mounted=null;
    constructor(parent, name, mode, rdev) {
      if (!parent) {
        parent = this;
      }
      // root node sets parent to itself
      this.parent = parent;
      this.mount = parent.mount;
      this.id = FS.nextInode++;
      this.name = name;
      this.mode = mode;
      this.rdev = rdev;
    }
    get read() {
      return (this.mode & this.readMode) === this.readMode;
    }
    set read(val) {
      val ? this.mode |= this.readMode : this.mode &= ~this.readMode;
    }
    get write() {
      return (this.mode & this.writeMode) === this.writeMode;
    }
    set write(val) {
      val ? this.mode |= this.writeMode : this.mode &= ~this.writeMode;
    }
    get isFolder() {
      return FS.isDir(this.mode);
    }
    get isDevice() {
      return FS.isChrdev(this.mode);
    }
  },
  lookupPath(path, opts = {}) {
    path = PATH_FS.resolve(path);
    if (!path) return {
      path: "",
      node: null
    };
    var defaults = {
      follow_mount: true,
      recurse_count: 0
    };
    opts = Object.assign(defaults, opts);
    if (opts.recurse_count > 8) {
      // max recursive lookup of 8
      throw new FS.ErrnoError(32);
    }
    // split the absolute path
    var parts = path.split("/").filter(p => !!p);
    // start at the root
    var current = FS.root;
    var current_path = "/";
    for (var i = 0; i < parts.length; i++) {
      var islast = (i === parts.length - 1);
      if (islast && opts.parent) {
        // stop resolving
        break;
      }
      current = FS.lookupNode(current, parts[i]);
      current_path = PATH.join2(current_path, parts[i]);
      // jump to the mount's root node if this is a mountpoint
      if (FS.isMountpoint(current)) {
        if (!islast || (islast && opts.follow_mount)) {
          current = current.mounted.root;
        }
      }
      // by default, lookupPath will not follow a symlink if it is the final path component.
      // setting opts.follow = true will override this behavior.
      if (!islast || opts.follow) {
        var count = 0;
        while (FS.isLink(current.mode)) {
          var link = FS.readlink(current_path);
          current_path = PATH_FS.resolve(PATH.dirname(current_path), link);
          var lookup = FS.lookupPath(current_path, {
            recurse_count: opts.recurse_count + 1
          });
          current = lookup.node;
          if (count++ > 40) {
            // limit max consecutive symlinks to 40 (SYMLOOP_MAX).
            throw new FS.ErrnoError(32);
          }
        }
      }
    }
    return {
      path: current_path,
      node: current
    };
  },
  getPath(node) {
    var path;
    while (true) {
      if (FS.isRoot(node)) {
        var mount = node.mount.mountpoint;
        if (!path) return mount;
        return mount[mount.length - 1] !== "/" ? `${mount}/${path}` : mount + path;
      }
      path = path ? `${node.name}/${path}` : node.name;
      node = node.parent;
    }
  },
  hashName(parentid, name) {
    var hash = 0;
    for (var i = 0; i < name.length; i++) {
      hash = ((hash << 5) - hash + name.charCodeAt(i)) | 0;
    }
    return ((parentid + hash) >>> 0) % FS.nameTable.length;
  },
  hashAddNode(node) {
    var hash = FS.hashName(node.parent.id, node.name);
    node.name_next = FS.nameTable[hash];
    FS.nameTable[hash] = node;
  },
  hashRemoveNode(node) {
    var hash = FS.hashName(node.parent.id, node.name);
    if (FS.nameTable[hash] === node) {
      FS.nameTable[hash] = node.name_next;
    } else {
      var current = FS.nameTable[hash];
      while (current) {
        if (current.name_next === node) {
          current.name_next = node.name_next;
          break;
        }
        current = current.name_next;
      }
    }
  },
  lookupNode(parent, name) {
    var errCode = FS.mayLookup(parent);
    if (errCode) {
      throw new FS.ErrnoError(errCode);
    }
    var hash = FS.hashName(parent.id, name);
    for (var node = FS.nameTable[hash]; node; node = node.name_next) {
      var nodeName = node.name;
      if (node.parent.id === parent.id && nodeName === name) {
        return node;
      }
    }
    // if we failed to find it in the cache, call into the VFS
    return FS.lookup(parent, name);
  },
  createNode(parent, name, mode, rdev) {
    var node = new FS.FSNode(parent, name, mode, rdev);
    FS.hashAddNode(node);
    return node;
  },
  destroyNode(node) {
    FS.hashRemoveNode(node);
  },
  isRoot(node) {
    return node === node.parent;
  },
  isMountpoint(node) {
    return !!node.mounted;
  },
  isFile(mode) {
    return (mode & 61440) === 32768;
  },
  isDir(mode) {
    return (mode & 61440) === 16384;
  },
  isLink(mode) {
    return (mode & 61440) === 40960;
  },
  isChrdev(mode) {
    return (mode & 61440) === 8192;
  },
  isBlkdev(mode) {
    return (mode & 61440) === 24576;
  },
  isFIFO(mode) {
    return (mode & 61440) === 4096;
  },
  isSocket(mode) {
    return (mode & 49152) === 49152;
  },
  flagsToPermissionString(flag) {
    var perms = [ "r", "w", "rw" ][flag & 3];
    if ((flag & 512)) {
      perms += "w";
    }
    return perms;
  },
  nodePermissions(node, perms) {
    if (FS.ignorePermissions) {
      return 0;
    }
    // return 0 if any user, group or owner bits are set.
    if (perms.includes("r") && !(node.mode & 292)) {
      return 2;
    } else if (perms.includes("w") && !(node.mode & 146)) {
      return 2;
    } else if (perms.includes("x") && !(node.mode & 73)) {
      return 2;
    }
    return 0;
  },
  mayLookup(dir) {
    if (!FS.isDir(dir.mode)) return 54;
    var errCode = FS.nodePermissions(dir, "x");
    if (errCode) return errCode;
    if (!dir.node_ops.lookup) return 2;
    return 0;
  },
  mayCreate(dir, name) {
    try {
      var node = FS.lookupNode(dir, name);
      return 20;
    } catch (e) {}
    return FS.nodePermissions(dir, "wx");
  },
  mayDelete(dir, name, isdir) {
    var node;
    try {
      node = FS.lookupNode(dir, name);
    } catch (e) {
      return e.errno;
    }
    var errCode = FS.nodePermissions(dir, "wx");
    if (errCode) {
      return errCode;
    }
    if (isdir) {
      if (!FS.isDir(node.mode)) {
        return 54;
      }
      if (FS.isRoot(node) || FS.getPath(node) === FS.cwd()) {
        return 10;
      }
    } else {
      if (FS.isDir(node.mode)) {
        return 31;
      }
    }
    return 0;
  },
  mayOpen(node, flags) {
    if (!node) {
      return 44;
    }
    if (FS.isLink(node.mode)) {
      return 32;
    } else if (FS.isDir(node.mode)) {
      if (FS.flagsToPermissionString(flags) !== "r" || // opening for write
      (flags & 512)) {
        // TODO: check for O_SEARCH? (== search for dir only)
        return 31;
      }
    }
    return FS.nodePermissions(node, FS.flagsToPermissionString(flags));
  },
  MAX_OPEN_FDS: 4096,
  nextfd() {
    for (var fd = 0; fd <= FS.MAX_OPEN_FDS; fd++) {
      if (!FS.streams[fd]) {
        return fd;
      }
    }
    throw new FS.ErrnoError(33);
  },
  getStreamChecked(fd) {
    var stream = FS.getStream(fd);
    if (!stream) {
      throw new FS.ErrnoError(8);
    }
    return stream;
  },
  getStream: fd => FS.streams[fd],
  createStream(stream, fd = -1) {
    // clone it, so we can return an instance of FSStream
    stream = Object.assign(new FS.FSStream, stream);
    if (fd == -1) {
      fd = FS.nextfd();
    }
    stream.fd = fd;
    FS.streams[fd] = stream;
    return stream;
  },
  closeStream(fd) {
    FS.streams[fd] = null;
  },
  dupStream(origStream, fd = -1) {
    var stream = FS.createStream(origStream, fd);
    stream.stream_ops?.dup?.(stream);
    return stream;
  },
  chrdev_stream_ops: {
    open(stream) {
      var device = FS.getDevice(stream.node.rdev);
      // override node's stream ops with the device's
      stream.stream_ops = device.stream_ops;
      // forward the open call
      stream.stream_ops.open?.(stream);
    },
    llseek() {
      throw new FS.ErrnoError(70);
    }
  },
  major: dev => ((dev) >> 8),
  minor: dev => ((dev) & 255),
  makedev: (ma, mi) => ((ma) << 8 | (mi)),
  registerDevice(dev, ops) {
    FS.devices[dev] = {
      stream_ops: ops
    };
  },
  getDevice: dev => FS.devices[dev],
  getMounts(mount) {
    var mounts = [];
    var check = [ mount ];
    while (check.length) {
      var m = check.pop();
      mounts.push(m);
      check.push(...m.mounts);
    }
    return mounts;
  },
  syncfs(populate, callback) {
    if (typeof populate == "function") {
      callback = populate;
      populate = false;
    }
    FS.syncFSRequests++;
    if (FS.syncFSRequests > 1) {
      err(`warning: ${FS.syncFSRequests} FS.syncfs operations in flight at once, probably just doing extra work`);
    }
    var mounts = FS.getMounts(FS.root.mount);
    var completed = 0;
    function doCallback(errCode) {
      FS.syncFSRequests--;
      return callback(errCode);
    }
    function done(errCode) {
      if (errCode) {
        if (!done.errored) {
          done.errored = true;
          return doCallback(errCode);
        }
        return;
      }
      if (++completed >= mounts.length) {
        doCallback(null);
      }
    }
    // sync all mounts
    mounts.forEach(mount => {
      if (!mount.type.syncfs) {
        return done(null);
      }
      mount.type.syncfs(mount, populate, done);
    });
  },
  mount(type, opts, mountpoint) {
    var root = mountpoint === "/";
    var pseudo = !mountpoint;
    var node;
    if (root && FS.root) {
      throw new FS.ErrnoError(10);
    } else if (!root && !pseudo) {
      var lookup = FS.lookupPath(mountpoint, {
        follow_mount: false
      });
      mountpoint = lookup.path;
      // use the absolute path
      node = lookup.node;
      if (FS.isMountpoint(node)) {
        throw new FS.ErrnoError(10);
      }
      if (!FS.isDir(node.mode)) {
        throw new FS.ErrnoError(54);
      }
    }
    var mount = {
      type,
      opts,
      mountpoint,
      mounts: []
    };
    // create a root node for the fs
    var mountRoot = type.mount(mount);
    mountRoot.mount = mount;
    mount.root = mountRoot;
    if (root) {
      FS.root = mountRoot;
    } else if (node) {
      // set as a mountpoint
      node.mounted = mount;
      // add the new mount to the current mount's children
      if (node.mount) {
        node.mount.mounts.push(mount);
      }
    }
    return mountRoot;
  },
  unmount(mountpoint) {
    var lookup = FS.lookupPath(mountpoint, {
      follow_mount: false
    });
    if (!FS.isMountpoint(lookup.node)) {
      throw new FS.ErrnoError(28);
    }
    // destroy the nodes for this mount, and all its child mounts
    var node = lookup.node;
    var mount = node.mounted;
    var mounts = FS.getMounts(mount);
    Object.keys(FS.nameTable).forEach(hash => {
      var current = FS.nameTable[hash];
      while (current) {
        var next = current.name_next;
        if (mounts.includes(current.mount)) {
          FS.destroyNode(current);
        }
        current = next;
      }
    });
    // no longer a mountpoint
    node.mounted = null;
    // remove this mount from the child mounts
    var idx = node.mount.mounts.indexOf(mount);
    node.mount.mounts.splice(idx, 1);
  },
  lookup(parent, name) {
    return parent.node_ops.lookup(parent, name);
  },
  mknod(path, mode, dev) {
    var lookup = FS.lookupPath(path, {
      parent: true
    });
    var parent = lookup.node;
    var name = PATH.basename(path);
    if (!name || name === "." || name === "..") {
      throw new FS.ErrnoError(28);
    }
    var errCode = FS.mayCreate(parent, name);
    if (errCode) {
      throw new FS.ErrnoError(errCode);
    }
    if (!parent.node_ops.mknod) {
      throw new FS.ErrnoError(63);
    }
    return parent.node_ops.mknod(parent, name, mode, dev);
  },
  statfs(path) {
    // NOTE: None of the defaults here are true. We're just returning safe and
    //       sane values.
    var rtn = {
      bsize: 4096,
      frsize: 4096,
      blocks: 1e6,
      bfree: 5e5,
      bavail: 5e5,
      files: FS.nextInode,
      ffree: FS.nextInode - 1,
      fsid: 42,
      flags: 2,
      namelen: 255
    };
    var parent = FS.lookupPath(path, {
      follow: true
    }).node;
    if (parent?.node_ops.statfs) {
      Object.assign(rtn, parent.node_ops.statfs(parent.mount.opts.root));
    }
    return rtn;
  },
  create(path, mode = 438) {
    mode &= 4095;
    mode |= 32768;
    return FS.mknod(path, mode, 0);
  },
  mkdir(path, mode = 511) {
    mode &= 511 | 512;
    mode |= 16384;
    return FS.mknod(path, mode, 0);
  },
  mkdirTree(path, mode) {
    var dirs = path.split("/");
    var d = "";
    for (var i = 0; i < dirs.length; ++i) {
      if (!dirs[i]) continue;
      d += "/" + dirs[i];
      try {
        FS.mkdir(d, mode);
      } catch (e) {
        if (e.errno != 20) throw e;
      }
    }
  },
  mkdev(path, mode, dev) {
    if (typeof dev == "undefined") {
      dev = mode;
      mode = 438;
    }
    mode |= 8192;
    return FS.mknod(path, mode, dev);
  },
  symlink(oldpath, newpath) {
    if (!PATH_FS.resolve(oldpath)) {
      throw new FS.ErrnoError(44);
    }
    var lookup = FS.lookupPath(newpath, {
      parent: true
    });
    var parent = lookup.node;
    if (!parent) {
      throw new FS.ErrnoError(44);
    }
    var newname = PATH.basename(newpath);
    var errCode = FS.mayCreate(parent, newname);
    if (errCode) {
      throw new FS.ErrnoError(errCode);
    }
    if (!parent.node_ops.symlink) {
      throw new FS.ErrnoError(63);
    }
    return parent.node_ops.symlink(parent, newname, oldpath);
  },
  rename(old_path, new_path) {
    var old_dirname = PATH.dirname(old_path);
    var new_dirname = PATH.dirname(new_path);
    var old_name = PATH.basename(old_path);
    var new_name = PATH.basename(new_path);
    // parents must exist
    var lookup, old_dir, new_dir;
    // let the errors from non existent directories percolate up
    lookup = FS.lookupPath(old_path, {
      parent: true
    });
    old_dir = lookup.node;
    lookup = FS.lookupPath(new_path, {
      parent: true
    });
    new_dir = lookup.node;
    if (!old_dir || !new_dir) throw new FS.ErrnoError(44);
    // need to be part of the same mount
    if (old_dir.mount !== new_dir.mount) {
      throw new FS.ErrnoError(75);
    }
    // source must exist
    var old_node = FS.lookupNode(old_dir, old_name);
    // old path should not be an ancestor of the new path
    var relative = PATH_FS.relative(old_path, new_dirname);
    if (relative.charAt(0) !== ".") {
      throw new FS.ErrnoError(28);
    }
    // new path should not be an ancestor of the old path
    relative = PATH_FS.relative(new_path, old_dirname);
    if (relative.charAt(0) !== ".") {
      throw new FS.ErrnoError(55);
    }
    // see if the new path already exists
    var new_node;
    try {
      new_node = FS.lookupNode(new_dir, new_name);
    } catch (e) {}
    // early out if nothing needs to change
    if (old_node === new_node) {
      return;
    }
    // we'll need to delete the old entry
    var isdir = FS.isDir(old_node.mode);
    var errCode = FS.mayDelete(old_dir, old_name, isdir);
    if (errCode) {
      throw new FS.ErrnoError(errCode);
    }
    // need delete permissions if we'll be overwriting.
    // need create permissions if new doesn't already exist.
    errCode = new_node ? FS.mayDelete(new_dir, new_name, isdir) : FS.mayCreate(new_dir, new_name);
    if (errCode) {
      throw new FS.ErrnoError(errCode);
    }
    if (!old_dir.node_ops.rename) {
      throw new FS.ErrnoError(63);
    }
    if (FS.isMountpoint(old_node) || (new_node && FS.isMountpoint(new_node))) {
      throw new FS.ErrnoError(10);
    }
    // if we are going to change the parent, check write permissions
    if (new_dir !== old_dir) {
      errCode = FS.nodePermissions(old_dir, "w");
      if (errCode) {
        throw new FS.ErrnoError(errCode);
      }
    }
    // remove the node from the lookup hash
    FS.hashRemoveNode(old_node);
    // do the underlying fs rename
    try {
      old_dir.node_ops.rename(old_node, new_dir, new_name);
      // update old node (we do this here to avoid each backend
      // needing to)
      old_node.parent = new_dir;
    } catch (e) {
      throw e;
    } finally {
      // add the node back to the hash (in case node_ops.rename
      // changed its name)
      FS.hashAddNode(old_node);
    }
  },
  rmdir(path) {
    var lookup = FS.lookupPath(path, {
      parent: true
    });
    var parent = lookup.node;
    var name = PATH.basename(path);
    var node = FS.lookupNode(parent, name);
    var errCode = FS.mayDelete(parent, name, true);
    if (errCode) {
      throw new FS.ErrnoError(errCode);
    }
    if (!parent.node_ops.rmdir) {
      throw new FS.ErrnoError(63);
    }
    if (FS.isMountpoint(node)) {
      throw new FS.ErrnoError(10);
    }
    parent.node_ops.rmdir(parent, name);
    FS.destroyNode(node);
  },
  readdir(path) {
    var lookup = FS.lookupPath(path, {
      follow: true
    });
    var node = lookup.node;
    if (!node.node_ops.readdir) {
      throw new FS.ErrnoError(54);
    }
    return node.node_ops.readdir(node);
  },
  unlink(path) {
    var lookup = FS.lookupPath(path, {
      parent: true
    });
    var parent = lookup.node;
    if (!parent) {
      throw new FS.ErrnoError(44);
    }
    var name = PATH.basename(path);
    var node = FS.lookupNode(parent, name);
    var errCode = FS.mayDelete(parent, name, false);
    if (errCode) {
      // According to POSIX, we should map EISDIR to EPERM, but
      // we instead do what Linux does (and we must, as we use
      // the musl linux libc).
      throw new FS.ErrnoError(errCode);
    }
    if (!parent.node_ops.unlink) {
      throw new FS.ErrnoError(63);
    }
    if (FS.isMountpoint(node)) {
      throw new FS.ErrnoError(10);
    }
    parent.node_ops.unlink(parent, name);
    FS.destroyNode(node);
  },
  readlink(path) {
    var lookup = FS.lookupPath(path);
    var link = lookup.node;
    if (!link) {
      throw new FS.ErrnoError(44);
    }
    if (!link.node_ops.readlink) {
      throw new FS.ErrnoError(28);
    }
    return link.node_ops.readlink(link);
  },
  stat(path, dontFollow) {
    var lookup = FS.lookupPath(path, {
      follow: !dontFollow
    });
    var node = lookup.node;
    if (!node) {
      throw new FS.ErrnoError(44);
    }
    if (!node.node_ops.getattr) {
      throw new FS.ErrnoError(63);
    }
    return node.node_ops.getattr(node);
  },
  lstat(path) {
    return FS.stat(path, true);
  },
  chmod(path, mode, dontFollow) {
    var node;
    if (typeof path == "string") {
      var lookup = FS.lookupPath(path, {
        follow: !dontFollow
      });
      node = lookup.node;
    } else {
      node = path;
    }
    if (!node.node_ops.setattr) {
      throw new FS.ErrnoError(63);
    }
    node.node_ops.setattr(node, {
      mode: (mode & 4095) | (node.mode & ~4095),
      timestamp: Date.now()
    });
  },
  lchmod(path, mode) {
    FS.chmod(path, mode, true);
  },
  fchmod(fd, mode) {
    var stream = FS.getStreamChecked(fd);
    FS.chmod(stream.node, mode);
  },
  chown(path, uid, gid, dontFollow) {
    var node;
    if (typeof path == "string") {
      var lookup = FS.lookupPath(path, {
        follow: !dontFollow
      });
      node = lookup.node;
    } else {
      node = path;
    }
    if (!node.node_ops.setattr) {
      throw new FS.ErrnoError(63);
    }
    node.node_ops.setattr(node, {
      timestamp: Date.now()
    });
  },
  // we ignore the uid / gid for now
  lchown(path, uid, gid) {
    FS.chown(path, uid, gid, true);
  },
  fchown(fd, uid, gid) {
    var stream = FS.getStreamChecked(fd);
    FS.chown(stream.node, uid, gid);
  },
  truncate(path, len) {
    if (len < 0) {
      throw new FS.ErrnoError(28);
    }
    var node;
    if (typeof path == "string") {
      var lookup = FS.lookupPath(path, {
        follow: true
      });
      node = lookup.node;
    } else {
      node = path;
    }
    if (!node.node_ops.setattr) {
      throw new FS.ErrnoError(63);
    }
    if (FS.isDir(node.mode)) {
      throw new FS.ErrnoError(31);
    }
    if (!FS.isFile(node.mode)) {
      throw new FS.ErrnoError(28);
    }
    var errCode = FS.nodePermissions(node, "w");
    if (errCode) {
      throw new FS.ErrnoError(errCode);
    }
    node.node_ops.setattr(node, {
      size: len,
      timestamp: Date.now()
    });
  },
  ftruncate(fd, len) {
    var stream = FS.getStreamChecked(fd);
    if ((stream.flags & 2097155) === 0) {
      throw new FS.ErrnoError(28);
    }
    FS.truncate(stream.node, len);
  },
  utime(path, atime, mtime) {
    var lookup = FS.lookupPath(path, {
      follow: true
    });
    var node = lookup.node;
    node.node_ops.setattr(node, {
      timestamp: Math.max(atime, mtime)
    });
  },
  open(path, flags, mode = 438) {
    if (path === "") {
      throw new FS.ErrnoError(44);
    }
    flags = typeof flags == "string" ? FS_modeStringToFlags(flags) : flags;
    if ((flags & 64)) {
      mode = (mode & 4095) | 32768;
    } else {
      mode = 0;
    }
    var node;
    if (typeof path == "object") {
      node = path;
    } else {
      path = PATH.normalize(path);
      try {
        var lookup = FS.lookupPath(path, {
          follow: !(flags & 131072)
        });
        node = lookup.node;
      } catch (e) {}
    }
    // perhaps we need to create the node
    var created = false;
    if ((flags & 64)) {
      if (node) {
        // if O_CREAT and O_EXCL are set, error out if the node already exists
        if ((flags & 128)) {
          throw new FS.ErrnoError(20);
        }
      } else {
        // node doesn't exist, try to create it
        node = FS.mknod(path, mode, 0);
        created = true;
      }
    }
    if (!node) {
      throw new FS.ErrnoError(44);
    }
    // can't truncate a device
    if (FS.isChrdev(node.mode)) {
      flags &= ~512;
    }
    // if asked only for a directory, then this must be one
    if ((flags & 65536) && !FS.isDir(node.mode)) {
      throw new FS.ErrnoError(54);
    }
    // check permissions, if this is not a file we just created now (it is ok to
    // create and write to a file with read-only permissions; it is read-only
    // for later use)
    if (!created) {
      var errCode = FS.mayOpen(node, flags);
      if (errCode) {
        throw new FS.ErrnoError(errCode);
      }
    }
    // do truncation if necessary
    if ((flags & 512) && !created) {
      FS.truncate(node, 0);
    }
    // we've already handled these, don't pass down to the underlying vfs
    flags &= ~(128 | 512 | 131072);
    // register the stream with the filesystem
    var stream = FS.createStream({
      node,
      path: FS.getPath(node),
      // we want the absolute path to the node
      flags,
      seekable: true,
      position: 0,
      stream_ops: node.stream_ops,
      // used by the file family libc calls (fopen, fwrite, ferror, etc.)
      ungotten: [],
      error: false
    });
    // call the new stream's open function
    if (stream.stream_ops.open) {
      stream.stream_ops.open(stream);
    }
    if (Module["logReadFiles"] && !(flags & 1)) {
      if (!(path in FS.readFiles)) {
        FS.readFiles[path] = 1;
      }
    }
    return stream;
  },
  close(stream) {
    if (FS.isClosed(stream)) {
      throw new FS.ErrnoError(8);
    }
    if (stream.getdents) stream.getdents = null;
    // free readdir state
    try {
      if (stream.stream_ops.close) {
        stream.stream_ops.close(stream);
      }
    } catch (e) {
      throw e;
    } finally {
      FS.closeStream(stream.fd);
    }
    stream.fd = null;
  },
  isClosed(stream) {
    return stream.fd === null;
  },
  llseek(stream, offset, whence) {
    if (FS.isClosed(stream)) {
      throw new FS.ErrnoError(8);
    }
    if (!stream.seekable || !stream.stream_ops.llseek) {
      throw new FS.ErrnoError(70);
    }
    if (whence != 0 && whence != 1 && whence != 2) {
      throw new FS.ErrnoError(28);
    }
    stream.position = stream.stream_ops.llseek(stream, offset, whence);
    stream.ungotten = [];
    return stream.position;
  },
  read(stream, buffer, offset, length, position) {
    if (length < 0 || position < 0) {
      throw new FS.ErrnoError(28);
    }
    if (FS.isClosed(stream)) {
      throw new FS.ErrnoError(8);
    }
    if ((stream.flags & 2097155) === 1) {
      throw new FS.ErrnoError(8);
    }
    if (FS.isDir(stream.node.mode)) {
      throw new FS.ErrnoError(31);
    }
    if (!stream.stream_ops.read) {
      throw new FS.ErrnoError(28);
    }
    var seeking = typeof position != "undefined";
    if (!seeking) {
      position = stream.position;
    } else if (!stream.seekable) {
      throw new FS.ErrnoError(70);
    }
    var bytesRead = stream.stream_ops.read(stream, buffer, offset, length, position);
    if (!seeking) stream.position += bytesRead;
    return bytesRead;
  },
  write(stream, buffer, offset, length, position, canOwn) {
    if (length < 0 || position < 0) {
      throw new FS.ErrnoError(28);
    }
    if (FS.isClosed(stream)) {
      throw new FS.ErrnoError(8);
    }
    if ((stream.flags & 2097155) === 0) {
      throw new FS.ErrnoError(8);
    }
    if (FS.isDir(stream.node.mode)) {
      throw new FS.ErrnoError(31);
    }
    if (!stream.stream_ops.write) {
      throw new FS.ErrnoError(28);
    }
    if (stream.seekable && stream.flags & 1024) {
      // seek to the end before writing in append mode
      FS.llseek(stream, 0, 2);
    }
    var seeking = typeof position != "undefined";
    if (!seeking) {
      position = stream.position;
    } else if (!stream.seekable) {
      throw new FS.ErrnoError(70);
    }
    var bytesWritten = stream.stream_ops.write(stream, buffer, offset, length, position, canOwn);
    if (!seeking) stream.position += bytesWritten;
    return bytesWritten;
  },
  allocate(stream, offset, length) {
    if (FS.isClosed(stream)) {
      throw new FS.ErrnoError(8);
    }
    if (offset < 0 || length <= 0) {
      throw new FS.ErrnoError(28);
    }
    if ((stream.flags & 2097155) === 0) {
      throw new FS.ErrnoError(8);
    }
    if (!FS.isFile(stream.node.mode) && !FS.isDir(stream.node.mode)) {
      throw new FS.ErrnoError(43);
    }
    if (!stream.stream_ops.allocate) {
      throw new FS.ErrnoError(138);
    }
    stream.stream_ops.allocate(stream, offset, length);
  },
  mmap(stream, length, position, prot, flags) {
    // User requests writing to file (prot & PROT_WRITE != 0).
    // Checking if we have permissions to write to the file unless
    // MAP_PRIVATE flag is set. According to POSIX spec it is possible
    // to write to file opened in read-only mode with MAP_PRIVATE flag,
    // as all modifications will be visible only in the memory of
    // the current process.
    if ((prot & 2) !== 0 && (flags & 2) === 0 && (stream.flags & 2097155) !== 2) {
      throw new FS.ErrnoError(2);
    }
    if ((stream.flags & 2097155) === 1) {
      throw new FS.ErrnoError(2);
    }
    if (!stream.stream_ops.mmap) {
      throw new FS.ErrnoError(43);
    }
    if (!length) {
      throw new FS.ErrnoError(28);
    }
    return stream.stream_ops.mmap(stream, length, position, prot, flags);
  },
  msync(stream, buffer, offset, length, mmapFlags) {
    if (!stream.stream_ops.msync) {
      return 0;
    }
    return stream.stream_ops.msync(stream, buffer, offset, length, mmapFlags);
  },
  ioctl(stream, cmd, arg) {
    if (!stream.stream_ops.ioctl) {
      throw new FS.ErrnoError(59);
    }
    return stream.stream_ops.ioctl(stream, cmd, arg);
  },
  readFile(path, opts = {}) {
    opts.flags = opts.flags || 0;
    opts.encoding = opts.encoding || "binary";
    if (opts.encoding !== "utf8" && opts.encoding !== "binary") {
      throw new Error(`Invalid encoding type "${opts.encoding}"`);
    }
    var ret;
    var stream = FS.open(path, opts.flags);
    var stat = FS.stat(path);
    var length = stat.size;
    var buf = new Uint8Array(length);
    FS.read(stream, buf, 0, length, 0);
    if (opts.encoding === "utf8") {
      ret = UTF8ArrayToString(buf);
    } else if (opts.encoding === "binary") {
      ret = buf;
    }
    FS.close(stream);
    return ret;
  },
  writeFile(path, data, opts = {}) {
    opts.flags = opts.flags || 577;
    var stream = FS.open(path, opts.flags, opts.mode);
    if (typeof data == "string") {
      var buf = new Uint8Array(lengthBytesUTF8(data) + 1);
      var actualNumBytes = stringToUTF8Array(data, buf, 0, buf.length);
      FS.write(stream, buf, 0, actualNumBytes, undefined, opts.canOwn);
    } else if (ArrayBuffer.isView(data)) {
      FS.write(stream, data, 0, data.byteLength, undefined, opts.canOwn);
    } else {
      throw new Error("Unsupported data type");
    }
    FS.close(stream);
  },
  cwd: () => FS.currentPath,
  chdir(path) {
    var lookup = FS.lookupPath(path, {
      follow: true
    });
    if (lookup.node === null) {
      throw new FS.ErrnoError(44);
    }
    if (!FS.isDir(lookup.node.mode)) {
      throw new FS.ErrnoError(54);
    }
    var errCode = FS.nodePermissions(lookup.node, "x");
    if (errCode) {
      throw new FS.ErrnoError(errCode);
    }
    FS.currentPath = lookup.path;
  },
  createDefaultDirectories() {
    FS.mkdir("/tmp");
    FS.mkdir("/home");
    FS.mkdir("/home/web_user");
  },
  createDefaultDevices() {
    // create /dev
    FS.mkdir("/dev");
    // setup /dev/null
    FS.registerDevice(FS.makedev(1, 3), {
      read: () => 0,
      write: (stream, buffer, offset, length, pos) => length,
      llseek: () => 0
    });
    FS.mkdev("/dev/null", FS.makedev(1, 3));
    // setup /dev/tty and /dev/tty1
    // stderr needs to print output using err() rather than out()
    // so we register a second tty just for it.
    TTY.register(FS.makedev(5, 0), TTY.default_tty_ops);
    TTY.register(FS.makedev(6, 0), TTY.default_tty1_ops);
    FS.mkdev("/dev/tty", FS.makedev(5, 0));
    FS.mkdev("/dev/tty1", FS.makedev(6, 0));
    // setup /dev/[u]random
    // use a buffer to avoid overhead of individual crypto calls per byte
    var randomBuffer = new Uint8Array(1024), randomLeft = 0;
    var randomByte = () => {
      if (randomLeft === 0) {
        randomLeft = randomFill(randomBuffer).byteLength;
      }
      return randomBuffer[--randomLeft];
    };
    FS.createDevice("/dev", "random", randomByte);
    FS.createDevice("/dev", "urandom", randomByte);
    // we're not going to emulate the actual shm device,
    // just create the tmp dirs that reside in it commonly
    FS.mkdir("/dev/shm");
    FS.mkdir("/dev/shm/tmp");
  },
  createSpecialDirectories() {
    // create /proc/self/fd which allows /proc/self/fd/6 => readlink gives the
    // name of the stream for fd 6 (see test_unistd_ttyname)
    FS.mkdir("/proc");
    var proc_self = FS.mkdir("/proc/self");
    FS.mkdir("/proc/self/fd");
    FS.mount({
      mount() {
        var node = FS.createNode(proc_self, "fd", 16895, 73);
        node.node_ops = {
          lookup(parent, name) {
            var fd = +name;
            var stream = FS.getStreamChecked(fd);
            var ret = {
              parent: null,
              mount: {
                mountpoint: "fake"
              },
              node_ops: {
                readlink: () => stream.path
              }
            };
            ret.parent = ret;
            // make it look like a simple root node
            return ret;
          }
        };
        return node;
      }
    }, {}, "/proc/self/fd");
  },
  createStandardStreams(input, output, error) {
    // TODO deprecate the old functionality of a single
    // input / output callback and that utilizes FS.createDevice
    // and instead require a unique set of stream ops
    // by default, we symlink the standard streams to the
    // default tty devices. however, if the standard streams
    // have been overwritten we create a unique device for
    // them instead.
    if (input) {
      FS.createDevice("/dev", "stdin", input);
    } else {
      FS.symlink("/dev/tty", "/dev/stdin");
    }
    if (output) {
      FS.createDevice("/dev", "stdout", null, output);
    } else {
      FS.symlink("/dev/tty", "/dev/stdout");
    }
    if (error) {
      FS.createDevice("/dev", "stderr", null, error);
    } else {
      FS.symlink("/dev/tty1", "/dev/stderr");
    }
    // open default streams for the stdin, stdout and stderr devices
    var stdin = FS.open("/dev/stdin", 0);
    var stdout = FS.open("/dev/stdout", 1);
    var stderr = FS.open("/dev/stderr", 1);
  },
  staticInit() {
    FS.nameTable = new Array(4096);
    FS.mount(MEMFS, {}, "/");
    FS.createDefaultDirectories();
    FS.createDefaultDevices();
    FS.createSpecialDirectories();
    FS.filesystems = {
      "MEMFS": MEMFS
    };
  },
  init(input, output, error) {
    FS.initialized = true;
    // Allow Module.stdin etc. to provide defaults, if none explicitly passed to us here
    input ??= Module["stdin"];
    output ??= Module["stdout"];
    error ??= Module["stderr"];
    FS.createStandardStreams(input, output, error);
  },
  quit() {
    FS.initialized = false;
    // force-flush all streams, so we get musl std streams printed out
    // close all of our streams
    for (var i = 0; i < FS.streams.length; i++) {
      var stream = FS.streams[i];
      if (!stream) {
        continue;
      }
      FS.close(stream);
    }
  },
  findObject(path, dontResolveLastLink) {
    var ret = FS.analyzePath(path, dontResolveLastLink);
    if (!ret.exists) {
      return null;
    }
    return ret.object;
  },
  analyzePath(path, dontResolveLastLink) {
    // operate from within the context of the symlink's target
    try {
      var lookup = FS.lookupPath(path, {
        follow: !dontResolveLastLink
      });
      path = lookup.path;
    } catch (e) {}
    var ret = {
      isRoot: false,
      exists: false,
      error: 0,
      name: null,
      path: null,
      object: null,
      parentExists: false,
      parentPath: null,
      parentObject: null
    };
    try {
      var lookup = FS.lookupPath(path, {
        parent: true
      });
      ret.parentExists = true;
      ret.parentPath = lookup.path;
      ret.parentObject = lookup.node;
      ret.name = PATH.basename(path);
      lookup = FS.lookupPath(path, {
        follow: !dontResolveLastLink
      });
      ret.exists = true;
      ret.path = lookup.path;
      ret.object = lookup.node;
      ret.name = lookup.node.name;
      ret.isRoot = lookup.path === "/";
    } catch (e) {
      ret.error = e.errno;
    }
    return ret;
  },
  createPath(parent, path, canRead, canWrite) {
    parent = typeof parent == "string" ? parent : FS.getPath(parent);
    var parts = path.split("/").reverse();
    while (parts.length) {
      var part = parts.pop();
      if (!part) continue;
      var current = PATH.join2(parent, part);
      try {
        FS.mkdir(current);
      } catch (e) {}
      // ignore EEXIST
      parent = current;
    }
    return current;
  },
  createFile(parent, name, properties, canRead, canWrite) {
    var path = PATH.join2(typeof parent == "string" ? parent : FS.getPath(parent), name);
    var mode = FS_getMode(canRead, canWrite);
    return FS.create(path, mode);
  },
  createDataFile(parent, name, data, canRead, canWrite, canOwn) {
    var path = name;
    if (parent) {
      parent = typeof parent == "string" ? parent : FS.getPath(parent);
      path = name ? PATH.join2(parent, name) : parent;
    }
    var mode = FS_getMode(canRead, canWrite);
    var node = FS.create(path, mode);
    if (data) {
      if (typeof data == "string") {
        var arr = new Array(data.length);
        for (var i = 0, len = data.length; i < len; ++i) arr[i] = data.charCodeAt(i);
        data = arr;
      }
      // make sure we can write to the file
      FS.chmod(node, mode | 146);
      var stream = FS.open(node, 577);
      FS.write(stream, data, 0, data.length, 0, canOwn);
      FS.close(stream);
      FS.chmod(node, mode);
    }
  },
  createDevice(parent, name, input, output) {
    var path = PATH.join2(typeof parent == "string" ? parent : FS.getPath(parent), name);
    var mode = FS_getMode(!!input, !!output);
    FS.createDevice.major ??= 64;
    var dev = FS.makedev(FS.createDevice.major++, 0);
    // Create a fake device that a set of stream ops to emulate
    // the old behavior.
    FS.registerDevice(dev, {
      open(stream) {
        stream.seekable = false;
      },
      close(stream) {
        // flush any pending line data
        if (output?.buffer?.length) {
          output(10);
        }
      },
      read(stream, buffer, offset, length, pos) {
        /* ignored */ var bytesRead = 0;
        for (var i = 0; i < length; i++) {
          var result;
          try {
            result = input();
          } catch (e) {
            throw new FS.ErrnoError(29);
          }
          if (result === undefined && bytesRead === 0) {
            throw new FS.ErrnoError(6);
          }
          if (result === null || result === undefined) break;
          bytesRead++;
          buffer[offset + i] = result;
        }
        if (bytesRead) {
          stream.node.timestamp = Date.now();
        }
        return bytesRead;
      },
      write(stream, buffer, offset, length, pos) {
        for (var i = 0; i < length; i++) {
          try {
            output(buffer[offset + i]);
          } catch (e) {
            throw new FS.ErrnoError(29);
          }
        }
        if (length) {
          stream.node.timestamp = Date.now();
        }
        return i;
      }
    });
    return FS.mkdev(path, mode, dev);
  },
  forceLoadFile(obj) {
    if (obj.isDevice || obj.isFolder || obj.link || obj.contents) return true;
    if (typeof XMLHttpRequest != "undefined") {
      throw new Error("Lazy loading should have been performed (contents set) in createLazyFile, but it was not. Lazy loading only works in web workers. Use --embed-file or --preload-file in emcc on the main thread.");
    } else {
      // Command-line.
      try {
        obj.contents = readBinary(obj.url);
        obj.usedBytes = obj.contents.length;
      } catch (e) {
        throw new FS.ErrnoError(29);
      }
    }
  },
  createLazyFile(parent, name, url, canRead, canWrite) {
    // Lazy chunked Uint8Array (implements get and length from Uint8Array).
    // Actual getting is abstracted away for eventual reuse.
    class LazyUint8Array {
      lengthKnown=false;
      chunks=[];
      // Loaded chunks. Index is the chunk number
      get(idx) {
        if (idx > this.length - 1 || idx < 0) {
          return undefined;
        }
        var chunkOffset = idx % this.chunkSize;
        var chunkNum = (idx / this.chunkSize) | 0;
        return this.getter(chunkNum)[chunkOffset];
      }
      setDataGetter(getter) {
        this.getter = getter;
      }
      cacheLength() {
        // Find length
        var xhr = new XMLHttpRequest;
        xhr.open("HEAD", url, false);
        xhr.send(null);
        if (!(xhr.status >= 200 && xhr.status < 300 || xhr.status === 304)) throw new Error("Couldn't load " + url + ". Status: " + xhr.status);
        var datalength = Number(xhr.getResponseHeader("Content-length"));
        var header;
        var hasByteServing = (header = xhr.getResponseHeader("Accept-Ranges")) && header === "bytes";
        var usesGzip = (header = xhr.getResponseHeader("Content-Encoding")) && header === "gzip";
        var chunkSize = 1024 * 1024;
        // Chunk size in bytes
        if (!hasByteServing) chunkSize = datalength;
        // Function to get a range from the remote URL.
        var doXHR = (from, to) => {
          if (from > to) throw new Error("invalid range (" + from + ", " + to + ") or no bytes requested!");
          if (to > datalength - 1) throw new Error("only " + datalength + " bytes available! programmer error!");
          // TODO: Use mozResponseArrayBuffer, responseStream, etc. if available.
          var xhr = new XMLHttpRequest;
          xhr.open("GET", url, false);
          if (datalength !== chunkSize) xhr.setRequestHeader("Range", "bytes=" + from + "-" + to);
          // Some hints to the browser that we want binary data.
          xhr.responseType = "arraybuffer";
          if (xhr.overrideMimeType) {
            xhr.overrideMimeType("text/plain; charset=x-user-defined");
          }
          xhr.send(null);
          if (!(xhr.status >= 200 && xhr.status < 300 || xhr.status === 304)) throw new Error("Couldn't load " + url + ". Status: " + xhr.status);
          if (xhr.response !== undefined) {
            return new Uint8Array(/** @type{Array<number>} */ (xhr.response || []));
          }
          return intArrayFromString(xhr.responseText || "", true);
        };
        var lazyArray = this;
        lazyArray.setDataGetter(chunkNum => {
          var start = chunkNum * chunkSize;
          var end = (chunkNum + 1) * chunkSize - 1;
          // including this byte
          end = Math.min(end, datalength - 1);
          // if datalength-1 is selected, this is the last block
          if (typeof lazyArray.chunks[chunkNum] == "undefined") {
            lazyArray.chunks[chunkNum] = doXHR(start, end);
          }
          if (typeof lazyArray.chunks[chunkNum] == "undefined") throw new Error("doXHR failed!");
          return lazyArray.chunks[chunkNum];
        });
        if (usesGzip || !datalength) {
          // if the server uses gzip or doesn't supply the length, we have to download the whole file to get the (uncompressed) length
          chunkSize = datalength = 1;
          // this will force getter(0)/doXHR do download the whole file
          datalength = this.getter(0).length;
          chunkSize = datalength;
          out("LazyFiles on gzip forces download of the whole file when length is accessed");
        }
        this._length = datalength;
        this._chunkSize = chunkSize;
        this.lengthKnown = true;
      }
      get length() {
        if (!this.lengthKnown) {
          this.cacheLength();
        }
        return this._length;
      }
      get chunkSize() {
        if (!this.lengthKnown) {
          this.cacheLength();
        }
        return this._chunkSize;
      }
    }
    if (typeof XMLHttpRequest != "undefined") {
      if (!ENVIRONMENT_IS_WORKER) throw "Cannot do synchronous binary XHRs outside webworkers in modern browsers. Use --embed-file or --preload-file in emcc";
      var lazyArray = new LazyUint8Array;
      var properties = {
        isDevice: false,
        contents: lazyArray
      };
    } else {
      var properties = {
        isDevice: false,
        url
      };
    }
    var node = FS.createFile(parent, name, properties, canRead, canWrite);
    // This is a total hack, but I want to get this lazy file code out of the
    // core of MEMFS. If we want to keep this lazy file concept I feel it should
    // be its own thin LAZYFS proxying calls to MEMFS.
    if (properties.contents) {
      node.contents = properties.contents;
    } else if (properties.url) {
      node.contents = null;
      node.url = properties.url;
    }
    // Add a function that defers querying the file size until it is asked the first time.
    Object.defineProperties(node, {
      usedBytes: {
        get: function() {
          return this.contents.length;
        }
      }
    });
    // override each stream op with one that tries to force load the lazy file first
    var stream_ops = {};
    var keys = Object.keys(node.stream_ops);
    keys.forEach(key => {
      var fn = node.stream_ops[key];
      stream_ops[key] = (...args) => {
        FS.forceLoadFile(node);
        return fn(...args);
      };
    });
    function writeChunks(stream, buffer, offset, length, position) {
      var contents = stream.node.contents;
      if (position >= contents.length) return 0;
      var size = Math.min(contents.length - position, length);
      if (contents.slice) {
        // normal array
        for (var i = 0; i < size; i++) {
          buffer[offset + i] = contents[position + i];
        }
      } else {
        for (var i = 0; i < size; i++) {
          // LazyUint8Array from sync binary XHR
          buffer[offset + i] = contents.get(position + i);
        }
      }
      return size;
    }
    // use a custom read function
    stream_ops.read = (stream, buffer, offset, length, position) => {
      FS.forceLoadFile(node);
      return writeChunks(stream, buffer, offset, length, position);
    };
    // use a custom mmap function
    stream_ops.mmap = (stream, length, position, prot, flags) => {
      FS.forceLoadFile(node);
      var ptr = mmapAlloc(length);
      if (!ptr) {
        throw new FS.ErrnoError(48);
      }
      writeChunks(stream, GROWABLE_HEAP_I8(), ptr, length, position);
      return {
        ptr,
        allocated: true
      };
    };
    node.stream_ops = stream_ops;
    return node;
  }
};

var SOCKFS = {
  websocketArgs: {},
  callbacks: {},
  on(event, callback) {
    SOCKFS.callbacks[event] = callback;
  },
  emit(event, param) {
    SOCKFS.callbacks[event]?.(param);
  },
  mount(mount) {
    // The incomming Module['websocket'] can be used for configuring 
    // configuring subprotocol/url, etc
    SOCKFS.websocketArgs = Module["websocket"] || {};
    // Add the Event registration mechanism to the exported websocket configuration
    // object so we can register network callbacks from native JavaScript too.
    // For more documentation see system/include/emscripten/emscripten.h
    (Module["websocket"] ??= {})["on"] = SOCKFS.on;
    return FS.createNode(null, "/", 16895, 0);
  },
  createSocket(family, type, protocol) {
    type &= ~526336;
    // Some applications may pass it; it makes no sense for a single process.
    var streaming = type == 1;
    if (streaming && protocol && protocol != 6) {
      throw new FS.ErrnoError(66);
    }
    // create our internal socket structure
    var sock = {
      family,
      type,
      protocol,
      server: null,
      error: null,
      // Used in getsockopt for SOL_SOCKET/SO_ERROR test
      peers: {},
      pending: [],
      recv_queue: [],
      sock_ops: SOCKFS.websocket_sock_ops
    };
    // create the filesystem node to store the socket structure
    var name = SOCKFS.nextname();
    var node = FS.createNode(SOCKFS.root, name, 49152, 0);
    node.sock = sock;
    // and the wrapping stream that enables library functions such
    // as read and write to indirectly interact with the socket
    var stream = FS.createStream({
      path: name,
      node,
      flags: 2,
      seekable: false,
      stream_ops: SOCKFS.stream_ops
    });
    // map the new stream to the socket structure (sockets have a 1:1
    // relationship with a stream)
    sock.stream = stream;
    return sock;
  },
  getSocket(fd) {
    var stream = FS.getStream(fd);
    if (!stream || !FS.isSocket(stream.node.mode)) {
      return null;
    }
    return stream.node.sock;
  },
  stream_ops: {
    poll(stream) {
      var sock = stream.node.sock;
      return sock.sock_ops.poll(sock);
    },
    ioctl(stream, request, varargs) {
      var sock = stream.node.sock;
      return sock.sock_ops.ioctl(sock, request, varargs);
    },
    read(stream, buffer, offset, length, position) {
      /* ignored */ var sock = stream.node.sock;
      var msg = sock.sock_ops.recvmsg(sock, length);
      if (!msg) {
        // socket is closed
        return 0;
      }
      buffer.set(msg.buffer, offset);
      return msg.buffer.length;
    },
    write(stream, buffer, offset, length, position) {
      /* ignored */ var sock = stream.node.sock;
      return sock.sock_ops.sendmsg(sock, buffer, offset, length);
    },
    close(stream) {
      var sock = stream.node.sock;
      sock.sock_ops.close(sock);
    }
  },
  nextname() {
    if (!SOCKFS.nextname.current) {
      SOCKFS.nextname.current = 0;
    }
    return `socket[${SOCKFS.nextname.current++}]`;
  },
  websocket_sock_ops: {
    createPeer(sock, addr, port) {
      var ws;
      if (typeof addr == "object") {
        ws = addr;
        addr = null;
        port = null;
      }
      if (ws) {
        // for sockets that've already connected (e.g. we're the server)
        // we can inspect the _socket property for the address
        if (ws._socket) {
          addr = ws._socket.remoteAddress;
          port = ws._socket.remotePort;
        } else // if we're just now initializing a connection to the remote,
        // inspect the url property
        {
          var result = /ws[s]?:\/\/([^:]+):(\d+)/.exec(ws.url);
          if (!result) {
            throw new Error("WebSocket URL must be in the format ws(s)://address:port");
          }
          addr = result[1];
          port = parseInt(result[2], 10);
        }
      } else {
        // create the actual websocket object and connect
        try {
          // The default value is 'ws://' the replace is needed because the compiler replaces '//' comments with '#'
          // comments without checking context, so we'd end up with ws:#, the replace swaps the '#' for '//' again.
          var url = "ws:#".replace("#", "//");
          // Make the WebSocket subprotocol (Sec-WebSocket-Protocol) default to binary if no configuration is set.
          var subProtocols = "binary";
          // The default value is 'binary'
          // The default WebSocket options
          var opts = undefined;
          // Fetch runtime WebSocket URL config.
          if (SOCKFS.websocketArgs["url"]) {
            url = SOCKFS.websocketArgs["url"];
          }
          // Fetch runtime WebSocket subprotocol config.
          if (SOCKFS.websocketArgs["subprotocol"]) {
            subProtocols = SOCKFS.websocketArgs["subprotocol"];
          } else if (SOCKFS.websocketArgs["subprotocol"] === null) {
            subProtocols = "null";
          }
          if (url === "ws://" || url === "wss://") {
            // Is the supplied URL config just a prefix, if so complete it.
            var parts = addr.split("/");
            url = url + parts[0] + ":" + port + "/" + parts.slice(1).join("/");
          }
          if (subProtocols !== "null") {
            // The regex trims the string (removes spaces at the beginning and end, then splits the string by
            // <any space>,<any space> into an Array. Whitespace removal is important for Websockify and ws.
            subProtocols = subProtocols.replace(/^ +| +$/g, "").split(/ *, */);
            opts = subProtocols;
          }
          // If node we use the ws library.
          var WebSocketConstructor;
          if (ENVIRONMENT_IS_NODE) {
            WebSocketConstructor = /** @type{(typeof WebSocket)} */ (require("ws"));
          } else {
            WebSocketConstructor = WebSocket;
          }
          ws = new WebSocketConstructor(url, opts);
          ws.binaryType = "arraybuffer";
        } catch (e) {
          throw new FS.ErrnoError(23);
        }
      }
      var peer = {
        addr,
        port,
        socket: ws,
        msg_send_queue: []
      };
      SOCKFS.websocket_sock_ops.addPeer(sock, peer);
      SOCKFS.websocket_sock_ops.handlePeerEvents(sock, peer);
      // if this is a bound dgram socket, send the port number first to allow
      // us to override the ephemeral port reported to us by remotePort on the
      // remote end.
      if (sock.type === 2 && typeof sock.sport != "undefined") {
        peer.msg_send_queue.push(new Uint8Array([ 255, 255, 255, 255, "p".charCodeAt(0), "o".charCodeAt(0), "r".charCodeAt(0), "t".charCodeAt(0), ((sock.sport & 65280) >> 8), (sock.sport & 255) ]));
      }
      return peer;
    },
    getPeer(sock, addr, port) {
      return sock.peers[addr + ":" + port];
    },
    addPeer(sock, peer) {
      sock.peers[peer.addr + ":" + peer.port] = peer;
    },
    removePeer(sock, peer) {
      delete sock.peers[peer.addr + ":" + peer.port];
    },
    handlePeerEvents(sock, peer) {
      var first = true;
      var handleOpen = function() {
        sock.connecting = false;
        SOCKFS.emit("open", sock.stream.fd);
        try {
          var queued = peer.msg_send_queue.shift();
          while (queued) {
            peer.socket.send(queued);
            queued = peer.msg_send_queue.shift();
          }
        } catch (e) {
          // not much we can do here in the way of proper error handling as we've already
          // lied and said this data was sent. shut it down.
          peer.socket.close();
        }
      };
      function handleMessage(data) {
        if (typeof data == "string") {
          var encoder = new TextEncoder;
          // should be utf-8
          data = encoder.encode(data);
        } else // make a typed array from the string
        {
          assert(data.byteLength !== undefined);
          // must receive an ArrayBuffer
          if (data.byteLength == 0) {
            // An empty ArrayBuffer will emit a pseudo disconnect event
            // as recv/recvmsg will return zero which indicates that a socket
            // has performed a shutdown although the connection has not been disconnected yet.
            return;
          }
          data = new Uint8Array(data);
        }
        // if this is the port message, override the peer's port with it
        var wasfirst = first;
        first = false;
        if (wasfirst && data.length === 10 && data[0] === 255 && data[1] === 255 && data[2] === 255 && data[3] === 255 && data[4] === "p".charCodeAt(0) && data[5] === "o".charCodeAt(0) && data[6] === "r".charCodeAt(0) && data[7] === "t".charCodeAt(0)) {
          // update the peer's port and it's key in the peer map
          var newport = ((data[8] << 8) | data[9]);
          SOCKFS.websocket_sock_ops.removePeer(sock, peer);
          peer.port = newport;
          SOCKFS.websocket_sock_ops.addPeer(sock, peer);
          return;
        }
        sock.recv_queue.push({
          addr: peer.addr,
          port: peer.port,
          data
        });
        SOCKFS.emit("message", sock.stream.fd);
      }
      if (ENVIRONMENT_IS_NODE) {
        peer.socket.on("open", handleOpen);
        peer.socket.on("message", function(data, isBinary) {
          if (!isBinary) {
            return;
          }
          handleMessage((new Uint8Array(data)).buffer);
        });
        // copy from node Buffer -> ArrayBuffer
        peer.socket.on("close", function() {
          SOCKFS.emit("close", sock.stream.fd);
        });
        peer.socket.on("error", function(error) {
          // Although the ws library may pass errors that may be more descriptive than
          // ECONNREFUSED they are not necessarily the expected error code e.g.
          // ENOTFOUND on getaddrinfo seems to be node.js specific, so using ECONNREFUSED
          // is still probably the most useful thing to do.
          sock.error = 14;
          // Used in getsockopt for SOL_SOCKET/SO_ERROR test.
          SOCKFS.emit("error", [ sock.stream.fd, sock.error, "ECONNREFUSED: Connection refused" ]);
        });
      } else {
        peer.socket.onopen = handleOpen;
        peer.socket.onclose = function() {
          SOCKFS.emit("close", sock.stream.fd);
        };
        peer.socket.onmessage = function peer_socket_onmessage(event) {
          handleMessage(event.data);
        };
        peer.socket.onerror = function(error) {
          // The WebSocket spec only allows a 'simple event' to be thrown on error,
          // so we only really know as much as ECONNREFUSED.
          sock.error = 14;
          // Used in getsockopt for SOL_SOCKET/SO_ERROR test.
          SOCKFS.emit("error", [ sock.stream.fd, sock.error, "ECONNREFUSED: Connection refused" ]);
        };
      }
    },
    poll(sock) {
      if (sock.type === 1 && sock.server) {
        // listen sockets should only say they're available for reading
        // if there are pending clients.
        return sock.pending.length ? (64 | 1) : 0;
      }
      var mask = 0;
      var dest = sock.type === 1 ? // we only care about the socket state for connection-based sockets
      SOCKFS.websocket_sock_ops.getPeer(sock, sock.daddr, sock.dport) : null;
      if (sock.recv_queue.length || !dest || // connection-less sockets are always ready to read
      (dest && dest.socket.readyState === dest.socket.CLOSING) || (dest && dest.socket.readyState === dest.socket.CLOSED)) {
        // let recv return 0 once closed
        mask |= (64 | 1);
      }
      if (!dest || // connection-less sockets are always ready to write
      (dest && dest.socket.readyState === dest.socket.OPEN)) {
        mask |= 4;
      }
      if ((dest && dest.socket.readyState === dest.socket.CLOSING) || (dest && dest.socket.readyState === dest.socket.CLOSED)) {
        // When an non-blocking connect fails mark the socket as writable.
        // Its up to the calling code to then use getsockopt with SO_ERROR to
        // retrieve the error.
        // See https://man7.org/linux/man-pages/man2/connect.2.html
        if (sock.connecting) {
          mask |= 4;
        } else {
          mask |= 16;
        }
      }
      return mask;
    },
    ioctl(sock, request, arg) {
      switch (request) {
       case 21531:
        var bytes = 0;
        if (sock.recv_queue.length) {
          bytes = sock.recv_queue[0].data.length;
        }
        GROWABLE_HEAP_I32()[((arg) >> 2)] = bytes;
        return 0;

       default:
        return 28;
      }
    },
    close(sock) {
      // if we've spawned a listen server, close it
      if (sock.server) {
        try {
          sock.server.close();
        } catch (e) {}
        sock.server = null;
      }
      // close any peer connections
      var peers = Object.keys(sock.peers);
      for (var i = 0; i < peers.length; i++) {
        var peer = sock.peers[peers[i]];
        try {
          peer.socket.close();
        } catch (e) {}
        SOCKFS.websocket_sock_ops.removePeer(sock, peer);
      }
      return 0;
    },
    bind(sock, addr, port) {
      if (typeof sock.saddr != "undefined" || typeof sock.sport != "undefined") {
        throw new FS.ErrnoError(28);
      }
      // already bound
      sock.saddr = addr;
      sock.sport = port;
      // in order to emulate dgram sockets, we need to launch a listen server when
      // binding on a connection-less socket
      // note: this is only required on the server side
      if (sock.type === 2) {
        // close the existing server if it exists
        if (sock.server) {
          sock.server.close();
          sock.server = null;
        }
        // swallow error operation not supported error that occurs when binding in the
        // browser where this isn't supported
        try {
          sock.sock_ops.listen(sock, 0);
        } catch (e) {
          if (!(e.name === "ErrnoError")) throw e;
          if (e.errno !== 138) throw e;
        }
      }
    },
    connect(sock, addr, port) {
      if (sock.server) {
        throw new FS.ErrnoError(138);
      }
      // TODO autobind
      // if (!sock.addr && sock.type == 2) {
      // }
      // early out if we're already connected / in the middle of connecting
      if (typeof sock.daddr != "undefined" && typeof sock.dport != "undefined") {
        var dest = SOCKFS.websocket_sock_ops.getPeer(sock, sock.daddr, sock.dport);
        if (dest) {
          if (dest.socket.readyState === dest.socket.CONNECTING) {
            throw new FS.ErrnoError(7);
          } else {
            throw new FS.ErrnoError(30);
          }
        }
      }
      // add the socket to our peer list and set our
      // destination address / port to match
      var peer = SOCKFS.websocket_sock_ops.createPeer(sock, addr, port);
      sock.daddr = peer.addr;
      sock.dport = peer.port;
      // because we cannot synchronously block to wait for the WebSocket
      // connection to complete, we return here pretending that the connection
      // was a success.
      sock.connecting = true;
    },
    listen(sock, backlog) {
      if (!ENVIRONMENT_IS_NODE) {
        throw new FS.ErrnoError(138);
      }
      if (sock.server) {
        throw new FS.ErrnoError(28);
      }
      // already listening
      var WebSocketServer = require("ws").Server;
      var host = sock.saddr;
      sock.server = new WebSocketServer({
        host,
        port: sock.sport
      });
      // TODO support backlog
      SOCKFS.emit("listen", sock.stream.fd);
      // Send Event with listen fd.
      sock.server.on("connection", function(ws) {
        if (sock.type === 1) {
          var newsock = SOCKFS.createSocket(sock.family, sock.type, sock.protocol);
          // create a peer on the new socket
          var peer = SOCKFS.websocket_sock_ops.createPeer(newsock, ws);
          newsock.daddr = peer.addr;
          newsock.dport = peer.port;
          // push to queue for accept to pick up
          sock.pending.push(newsock);
          SOCKFS.emit("connection", newsock.stream.fd);
        } else {
          // create a peer on the listen socket so calling sendto
          // with the listen socket and an address will resolve
          // to the correct client
          SOCKFS.websocket_sock_ops.createPeer(sock, ws);
          SOCKFS.emit("connection", sock.stream.fd);
        }
      });
      sock.server.on("close", function() {
        SOCKFS.emit("close", sock.stream.fd);
        sock.server = null;
      });
      sock.server.on("error", function(error) {
        // Although the ws library may pass errors that may be more descriptive than
        // ECONNREFUSED they are not necessarily the expected error code e.g.
        // ENOTFOUND on getaddrinfo seems to be node.js specific, so using EHOSTUNREACH
        // is still probably the most useful thing to do. This error shouldn't
        // occur in a well written app as errors should get trapped in the compiled
        // app's own getaddrinfo call.
        sock.error = 23;
        // Used in getsockopt for SOL_SOCKET/SO_ERROR test.
        SOCKFS.emit("error", [ sock.stream.fd, sock.error, "EHOSTUNREACH: Host is unreachable" ]);
      });
    },
    // don't throw
    accept(listensock) {
      if (!listensock.server || !listensock.pending.length) {
        throw new FS.ErrnoError(28);
      }
      var newsock = listensock.pending.shift();
      newsock.stream.flags = listensock.stream.flags;
      return newsock;
    },
    getname(sock, peer) {
      var addr, port;
      if (peer) {
        if (sock.daddr === undefined || sock.dport === undefined) {
          throw new FS.ErrnoError(53);
        }
        addr = sock.daddr;
        port = sock.dport;
      } else {
        // TODO saddr and sport will be set for bind()'d UDP sockets, but what
        // should we be returning for TCP sockets that've been connect()'d?
        addr = sock.saddr || 0;
        port = sock.sport || 0;
      }
      return {
        addr,
        port
      };
    },
    sendmsg(sock, buffer, offset, length, addr, port) {
      if (sock.type === 2) {
        // connection-less sockets will honor the message address,
        // and otherwise fall back to the bound destination address
        if (addr === undefined || port === undefined) {
          addr = sock.daddr;
          port = sock.dport;
        }
        // if there was no address to fall back to, error out
        if (addr === undefined || port === undefined) {
          throw new FS.ErrnoError(17);
        }
      } else {
        // connection-based sockets will only use the bound
        addr = sock.daddr;
        port = sock.dport;
      }
      // find the peer for the destination address
      var dest = SOCKFS.websocket_sock_ops.getPeer(sock, addr, port);
      // early out if not connected with a connection-based socket
      if (sock.type === 1) {
        if (!dest || dest.socket.readyState === dest.socket.CLOSING || dest.socket.readyState === dest.socket.CLOSED) {
          throw new FS.ErrnoError(53);
        }
      }
      // create a copy of the incoming data to send, as the WebSocket API
      // doesn't work entirely with an ArrayBufferView, it'll just send
      // the entire underlying buffer
      if (ArrayBuffer.isView(buffer)) {
        offset += buffer.byteOffset;
        buffer = buffer.buffer;
      }
      var data = buffer.slice(offset, offset + length);
      // WebSockets .send() does not allow passing a SharedArrayBuffer, so
      // clone the the SharedArrayBuffer as regular ArrayBuffer before
      // sending.
      if (data instanceof SharedArrayBuffer) {
        data = new Uint8Array(new Uint8Array(data)).buffer;
      }
      // if we don't have a cached connectionless UDP datagram connection, or
      // the TCP socket is still connecting, queue the message to be sent upon
      // connect, and lie, saying the data was sent now.
      if (!dest || dest.socket.readyState !== dest.socket.OPEN) {
        // if we're not connected, open a new connection
        if (sock.type === 2) {
          if (!dest || dest.socket.readyState === dest.socket.CLOSING || dest.socket.readyState === dest.socket.CLOSED) {
            dest = SOCKFS.websocket_sock_ops.createPeer(sock, addr, port);
          }
        }
        dest.msg_send_queue.push(data);
        return length;
      }
      try {
        // send the actual data
        dest.socket.send(data);
        return length;
      } catch (e) {
        throw new FS.ErrnoError(28);
      }
    },
    recvmsg(sock, length) {
      // http://pubs.opengroup.org/onlinepubs/7908799/xns/recvmsg.html
      if (sock.type === 1 && sock.server) {
        // tcp servers should not be recv()'ing on the listen socket
        throw new FS.ErrnoError(53);
      }
      var queued = sock.recv_queue.shift();
      if (!queued) {
        if (sock.type === 1) {
          var dest = SOCKFS.websocket_sock_ops.getPeer(sock, sock.daddr, sock.dport);
          if (!dest) {
            // if we have a destination address but are not connected, error out
            throw new FS.ErrnoError(53);
          }
          if (dest.socket.readyState === dest.socket.CLOSING || dest.socket.readyState === dest.socket.CLOSED) {
            // return null if the socket has closed
            return null;
          }
          // else, our socket is in a valid state but truly has nothing available
          throw new FS.ErrnoError(6);
        }
        throw new FS.ErrnoError(6);
      }
      // queued.data will be an ArrayBuffer if it's unadulterated, but if it's
      // requeued TCP data it'll be an ArrayBufferView
      var queuedLength = queued.data.byteLength || queued.data.length;
      var queuedOffset = queued.data.byteOffset || 0;
      var queuedBuffer = queued.data.buffer || queued.data;
      var bytesRead = Math.min(length, queuedLength);
      var res = {
        buffer: new Uint8Array(queuedBuffer, queuedOffset, bytesRead),
        addr: queued.addr,
        port: queued.port
      };
      // push back any unread data for TCP connections
      if (sock.type === 1 && bytesRead < queuedLength) {
        var bytesRemaining = queuedLength - bytesRead;
        queued.data = new Uint8Array(queuedBuffer, queuedOffset + bytesRead, bytesRemaining);
        sock.recv_queue.unshift(queued);
      }
      return res;
    }
  }
};

var getSocketFromFD = fd => {
  var socket = SOCKFS.getSocket(fd);
  if (!socket) throw new FS.ErrnoError(8);
  return socket;
};

var Sockets = {
  BUFFER_SIZE: 10240,
  MAX_BUFFER_SIZE: 10485760,
  nextFd: 1,
  fds: {},
  nextport: 1,
  maxport: 65535,
  peer: null,
  connections: {},
  portmap: {},
  localAddr: 4261412874,
  addrPool: [ 33554442, 50331658, 67108874, 83886090, 100663306, 117440522, 134217738, 150994954, 167772170, 184549386, 201326602, 218103818, 234881034 ]
};

var inetNtop4 = addr => (addr & 255) + "." + ((addr >> 8) & 255) + "." + ((addr >> 16) & 255) + "." + ((addr >> 24) & 255);

var inetNtop6 = ints => {
  //  ref:  http://www.ietf.org/rfc/rfc2373.txt - section 2.5.4
  //  Format for IPv4 compatible and mapped  128-bit IPv6 Addresses
  //  128-bits are split into eight 16-bit words
  //  stored in network byte order (big-endian)
  //  |                80 bits               | 16 |      32 bits        |
  //  +-----------------------------------------------------------------+
  //  |               10 bytes               |  2 |      4 bytes        |
  //  +--------------------------------------+--------------------------+
  //  +               5 words                |  1 |      2 words        |
  //  +--------------------------------------+--------------------------+
  //  |0000..............................0000|0000|    IPv4 ADDRESS     | (compatible)
  //  +--------------------------------------+----+---------------------+
  //  |0000..............................0000|FFFF|    IPv4 ADDRESS     | (mapped)
  //  +--------------------------------------+----+---------------------+
  var str = "";
  var word = 0;
  var longest = 0;
  var lastzero = 0;
  var zstart = 0;
  var len = 0;
  var i = 0;
  var parts = [ ints[0] & 65535, (ints[0] >> 16), ints[1] & 65535, (ints[1] >> 16), ints[2] & 65535, (ints[2] >> 16), ints[3] & 65535, (ints[3] >> 16) ];
  // Handle IPv4-compatible, IPv4-mapped, loopback and any/unspecified addresses
  var hasipv4 = true;
  var v4part = "";
  // check if the 10 high-order bytes are all zeros (first 5 words)
  for (i = 0; i < 5; i++) {
    if (parts[i] !== 0) {
      hasipv4 = false;
      break;
    }
  }
  if (hasipv4) {
    // low-order 32-bits store an IPv4 address (bytes 13 to 16) (last 2 words)
    v4part = inetNtop4(parts[6] | (parts[7] << 16));
    // IPv4-mapped IPv6 address if 16-bit value (bytes 11 and 12) == 0xFFFF (6th word)
    if (parts[5] === -1) {
      str = "::ffff:";
      str += v4part;
      return str;
    }
    // IPv4-compatible IPv6 address if 16-bit value (bytes 11 and 12) == 0x0000 (6th word)
    if (parts[5] === 0) {
      str = "::";
      //special case IPv6 addresses
      if (v4part === "0.0.0.0") v4part = "";
      // any/unspecified address
      if (v4part === "0.0.0.1") v4part = "1";
      // loopback address
      str += v4part;
      return str;
    }
  }
  // Handle all other IPv6 addresses
  // first run to find the longest contiguous zero words
  for (word = 0; word < 8; word++) {
    if (parts[word] === 0) {
      if (word - lastzero > 1) {
        len = 0;
      }
      lastzero = word;
      len++;
    }
    if (len > longest) {
      longest = len;
      zstart = word - longest + 1;
    }
  }
  for (word = 0; word < 8; word++) {
    if (longest > 1) {
      // compress contiguous zeros - to produce "::"
      if (parts[word] === 0 && word >= zstart && word < (zstart + longest)) {
        if (word === zstart) {
          str += ":";
          if (zstart === 0) str += ":";
        }
        //leading zeros case
        continue;
      }
    }
    // converts 16-bit words from big-endian to little-endian before converting to hex string
    str += Number(_ntohs(parts[word] & 65535)).toString(16);
    str += word < 7 ? ":" : "";
  }
  return str;
};

var readSockaddr = (sa, salen) => {
  // family / port offsets are common to both sockaddr_in and sockaddr_in6
  var family = GROWABLE_HEAP_I16()[((sa) >> 1)];
  var port = _ntohs(GROWABLE_HEAP_U16()[(((sa) + (2)) >> 1)]);
  var addr;
  switch (family) {
   case 2:
    if (salen !== 16) {
      return {
        errno: 28
      };
    }
    addr = GROWABLE_HEAP_I32()[(((sa) + (4)) >> 2)];
    addr = inetNtop4(addr);
    break;

   case 10:
    if (salen !== 28) {
      return {
        errno: 28
      };
    }
    addr = [ GROWABLE_HEAP_I32()[(((sa) + (8)) >> 2)], GROWABLE_HEAP_I32()[(((sa) + (12)) >> 2)], GROWABLE_HEAP_I32()[(((sa) + (16)) >> 2)], GROWABLE_HEAP_I32()[(((sa) + (20)) >> 2)] ];
    addr = inetNtop6(addr);
    break;

   default:
    return {
      errno: 5
    };
  }
  return {
    family,
    addr,
    port
  };
};

var inetPton4 = str => {
  var b = str.split(".");
  for (var i = 0; i < 4; i++) {
    var tmp = Number(b[i]);
    if (isNaN(tmp)) return null;
    b[i] = tmp;
  }
  return (b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)) >>> 0;
};

/** @suppress {checkTypes} */ var jstoi_q = str => parseInt(str);

var inetPton6 = str => {
  var words;
  var w, offset, z, i;
  /* http://home.deds.nl/~aeron/regex/ */ var valid6regx = /^((?=.*::)(?!.*::.+::)(::)?([\dA-F]{1,4}:(:|\b)|){5}|([\dA-F]{1,4}:){6})((([\dA-F]{1,4}((?!\3)::|:\b|$))|(?!\2\3)){2}|(((2[0-4]|1\d|[1-9])?\d|25[0-5])\.?\b){4})$/i;
  var parts = [];
  if (!valid6regx.test(str)) {
    return null;
  }
  if (str === "::") {
    return [ 0, 0, 0, 0, 0, 0, 0, 0 ];
  }
  // Z placeholder to keep track of zeros when splitting the string on ":"
  if (str.startsWith("::")) {
    str = str.replace("::", "Z:");
  } else // leading zeros case
  {
    str = str.replace("::", ":Z:");
  }
  if (str.indexOf(".") > 0) {
    // parse IPv4 embedded stress
    str = str.replace(new RegExp("[.]", "g"), ":");
    words = str.split(":");
    words[words.length - 4] = jstoi_q(words[words.length - 4]) + jstoi_q(words[words.length - 3]) * 256;
    words[words.length - 3] = jstoi_q(words[words.length - 2]) + jstoi_q(words[words.length - 1]) * 256;
    words = words.slice(0, words.length - 2);
  } else {
    words = str.split(":");
  }
  offset = 0;
  z = 0;
  for (w = 0; w < words.length; w++) {
    if (typeof words[w] == "string") {
      if (words[w] === "Z") {
        // compressed zeros - write appropriate number of zero words
        for (z = 0; z < (8 - words.length + 1); z++) {
          parts[w + z] = 0;
        }
        offset = z - 1;
      } else {
        // parse hex to field to 16-bit value and write it in network byte-order
        parts[w + offset] = _htons(parseInt(words[w], 16));
      }
    } else {
      // parsed IPv4 words
      parts[w + offset] = words[w];
    }
  }
  return [ (parts[1] << 16) | parts[0], (parts[3] << 16) | parts[2], (parts[5] << 16) | parts[4], (parts[7] << 16) | parts[6] ];
};

var DNS = {
  address_map: {
    id: 1,
    addrs: {},
    names: {}
  },
  lookup_name(name) {
    // If the name is already a valid ipv4 / ipv6 address, don't generate a fake one.
    var res = inetPton4(name);
    if (res !== null) {
      return name;
    }
    res = inetPton6(name);
    if (res !== null) {
      return name;
    }
    // See if this name is already mapped.
    var addr;
    if (DNS.address_map.addrs[name]) {
      addr = DNS.address_map.addrs[name];
    } else {
      var id = DNS.address_map.id++;
      assert(id < 65535, "exceeded max address mappings of 65535");
      addr = "172.29." + (id & 255) + "." + (id & 65280);
      DNS.address_map.names[addr] = name;
      DNS.address_map.addrs[name] = addr;
    }
    return addr;
  },
  lookup_addr(addr) {
    if (DNS.address_map.names[addr]) {
      return DNS.address_map.names[addr];
    }
    return null;
  }
};

var getSocketAddress = (addrp, addrlen) => {
  var info = readSockaddr(addrp, addrlen);
  if (info.errno) throw new FS.ErrnoError(info.errno);
  info.addr = DNS.lookup_addr(info.addr) || info.addr;
  return info;
};

function ___syscall_bind(fd, addr, addrlen, d1, d2, d3) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(2, 0, 1, fd, addr, addrlen, d1, d2, d3);
  try {
    var sock = getSocketFromFD(fd);
    var info = getSocketAddress(addr, addrlen);
    sock.sock_ops.bind(sock, info.addr, info.port);
    return 0;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_connect(fd, addr, addrlen, d1, d2, d3) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(3, 0, 1, fd, addr, addrlen, d1, d2, d3);
  try {
    var sock = getSocketFromFD(fd);
    var info = getSocketAddress(addr, addrlen);
    sock.sock_ops.connect(sock, info.addr, info.port);
    return 0;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

/** @suppress {duplicate } */ var syscallGetVarargI = () => {
  // the `+` prepended here is necessary to convince the JSCompiler that varargs is indeed a number.
  var ret = GROWABLE_HEAP_I32()[((+SYSCALLS.varargs) >> 2)];
  SYSCALLS.varargs += 4;
  return ret;
};

var syscallGetVarargP = syscallGetVarargI;

var SYSCALLS = {
  DEFAULT_POLLMASK: 5,
  calculateAt(dirfd, path, allowEmpty) {
    if (PATH.isAbs(path)) {
      return path;
    }
    // relative path
    var dir;
    if (dirfd === -100) {
      dir = FS.cwd();
    } else {
      var dirstream = SYSCALLS.getStreamFromFD(dirfd);
      dir = dirstream.path;
    }
    if (path.length == 0) {
      if (!allowEmpty) {
        throw new FS.ErrnoError(44);
      }
      return dir;
    }
    return PATH.join2(dir, path);
  },
  doStat(func, path, buf) {
    var stat = func(path);
    GROWABLE_HEAP_I32()[((buf) >> 2)] = stat.dev;
    GROWABLE_HEAP_I32()[(((buf) + (4)) >> 2)] = stat.mode;
    GROWABLE_HEAP_U32()[(((buf) + (8)) >> 2)] = stat.nlink;
    GROWABLE_HEAP_I32()[(((buf) + (12)) >> 2)] = stat.uid;
    GROWABLE_HEAP_I32()[(((buf) + (16)) >> 2)] = stat.gid;
    GROWABLE_HEAP_I32()[(((buf) + (20)) >> 2)] = stat.rdev;
    (tempI64 = [ stat.size >>> 0, (tempDouble = stat.size, (+(Math.abs(tempDouble))) >= 1 ? (tempDouble > 0 ? (+(Math.floor((tempDouble) / 4294967296))) >>> 0 : (~~((+(Math.ceil((tempDouble - +(((~~(tempDouble))) >>> 0)) / 4294967296))))) >>> 0) : 0) ], 
    GROWABLE_HEAP_I32()[(((buf) + (24)) >> 2)] = tempI64[0], GROWABLE_HEAP_I32()[(((buf) + (28)) >> 2)] = tempI64[1]);
    GROWABLE_HEAP_I32()[(((buf) + (32)) >> 2)] = 4096;
    GROWABLE_HEAP_I32()[(((buf) + (36)) >> 2)] = stat.blocks;
    var atime = stat.atime.getTime();
    var mtime = stat.mtime.getTime();
    var ctime = stat.ctime.getTime();
    (tempI64 = [ Math.floor(atime / 1e3) >>> 0, (tempDouble = Math.floor(atime / 1e3), 
    (+(Math.abs(tempDouble))) >= 1 ? (tempDouble > 0 ? (+(Math.floor((tempDouble) / 4294967296))) >>> 0 : (~~((+(Math.ceil((tempDouble - +(((~~(tempDouble))) >>> 0)) / 4294967296))))) >>> 0) : 0) ], 
    GROWABLE_HEAP_I32()[(((buf) + (40)) >> 2)] = tempI64[0], GROWABLE_HEAP_I32()[(((buf) + (44)) >> 2)] = tempI64[1]);
    GROWABLE_HEAP_U32()[(((buf) + (48)) >> 2)] = (atime % 1e3) * 1e3 * 1e3;
    (tempI64 = [ Math.floor(mtime / 1e3) >>> 0, (tempDouble = Math.floor(mtime / 1e3), 
    (+(Math.abs(tempDouble))) >= 1 ? (tempDouble > 0 ? (+(Math.floor((tempDouble) / 4294967296))) >>> 0 : (~~((+(Math.ceil((tempDouble - +(((~~(tempDouble))) >>> 0)) / 4294967296))))) >>> 0) : 0) ], 
    GROWABLE_HEAP_I32()[(((buf) + (56)) >> 2)] = tempI64[0], GROWABLE_HEAP_I32()[(((buf) + (60)) >> 2)] = tempI64[1]);
    GROWABLE_HEAP_U32()[(((buf) + (64)) >> 2)] = (mtime % 1e3) * 1e3 * 1e3;
    (tempI64 = [ Math.floor(ctime / 1e3) >>> 0, (tempDouble = Math.floor(ctime / 1e3), 
    (+(Math.abs(tempDouble))) >= 1 ? (tempDouble > 0 ? (+(Math.floor((tempDouble) / 4294967296))) >>> 0 : (~~((+(Math.ceil((tempDouble - +(((~~(tempDouble))) >>> 0)) / 4294967296))))) >>> 0) : 0) ], 
    GROWABLE_HEAP_I32()[(((buf) + (72)) >> 2)] = tempI64[0], GROWABLE_HEAP_I32()[(((buf) + (76)) >> 2)] = tempI64[1]);
    GROWABLE_HEAP_U32()[(((buf) + (80)) >> 2)] = (ctime % 1e3) * 1e3 * 1e3;
    (tempI64 = [ stat.ino >>> 0, (tempDouble = stat.ino, (+(Math.abs(tempDouble))) >= 1 ? (tempDouble > 0 ? (+(Math.floor((tempDouble) / 4294967296))) >>> 0 : (~~((+(Math.ceil((tempDouble - +(((~~(tempDouble))) >>> 0)) / 4294967296))))) >>> 0) : 0) ], 
    GROWABLE_HEAP_I32()[(((buf) + (88)) >> 2)] = tempI64[0], GROWABLE_HEAP_I32()[(((buf) + (92)) >> 2)] = tempI64[1]);
    return 0;
  },
  doMsync(addr, stream, len, flags, offset) {
    if (!FS.isFile(stream.node.mode)) {
      throw new FS.ErrnoError(43);
    }
    if (flags & 2) {
      // MAP_PRIVATE calls need not to be synced back to underlying fs
      return 0;
    }
    var buffer = GROWABLE_HEAP_U8().slice(addr, addr + len);
    FS.msync(stream, buffer, offset, len, flags);
  },
  getStreamFromFD(fd) {
    var stream = FS.getStreamChecked(fd);
    return stream;
  },
  varargs: undefined,
  getStr(ptr) {
    var ret = UTF8ToString(ptr);
    return ret;
  }
};

function ___syscall_fcntl64(fd, cmd, varargs) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(4, 0, 1, fd, cmd, varargs);
  SYSCALLS.varargs = varargs;
  try {
    var stream = SYSCALLS.getStreamFromFD(fd);
    switch (cmd) {
     case 0:
      {
        var arg = syscallGetVarargI();
        if (arg < 0) {
          return -28;
        }
        while (FS.streams[arg]) {
          arg++;
        }
        var newStream;
        newStream = FS.dupStream(stream, arg);
        return newStream.fd;
      }

     case 1:
     case 2:
      return 0;

     // FD_CLOEXEC makes no sense for a single process.
      case 3:
      return stream.flags;

     case 4:
      {
        var arg = syscallGetVarargI();
        stream.flags |= arg;
        return 0;
      }

     case 12:
      {
        var arg = syscallGetVarargP();
        var offset = 0;
        // We're always unlocked.
        GROWABLE_HEAP_I16()[(((arg) + (offset)) >> 1)] = 2;
        return 0;
      }

     case 13:
     case 14:
      return 0;
    }
    // Pretend that the locking is successful.
    return -28;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_fstat64(fd, buf) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(5, 0, 1, fd, buf);
  try {
    var stream = SYSCALLS.getStreamFromFD(fd);
    return SYSCALLS.doStat(FS.stat, stream.path, buf);
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

/** @param {number=} addrlen */ var writeSockaddr = (sa, family, addr, port, addrlen) => {
  switch (family) {
   case 2:
    addr = inetPton4(addr);
    zeroMemory(sa, 16);
    if (addrlen) {
      GROWABLE_HEAP_I32()[((addrlen) >> 2)] = 16;
    }
    GROWABLE_HEAP_I16()[((sa) >> 1)] = family;
    GROWABLE_HEAP_I32()[(((sa) + (4)) >> 2)] = addr;
    GROWABLE_HEAP_I16()[(((sa) + (2)) >> 1)] = _htons(port);
    break;

   case 10:
    addr = inetPton6(addr);
    zeroMemory(sa, 28);
    if (addrlen) {
      GROWABLE_HEAP_I32()[((addrlen) >> 2)] = 28;
    }
    GROWABLE_HEAP_I32()[((sa) >> 2)] = family;
    GROWABLE_HEAP_I32()[(((sa) + (8)) >> 2)] = addr[0];
    GROWABLE_HEAP_I32()[(((sa) + (12)) >> 2)] = addr[1];
    GROWABLE_HEAP_I32()[(((sa) + (16)) >> 2)] = addr[2];
    GROWABLE_HEAP_I32()[(((sa) + (20)) >> 2)] = addr[3];
    GROWABLE_HEAP_I16()[(((sa) + (2)) >> 1)] = _htons(port);
    break;

   default:
    return 5;
  }
  return 0;
};

function ___syscall_getpeername(fd, addr, addrlen, d1, d2, d3) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(6, 0, 1, fd, addr, addrlen, d1, d2, d3);
  try {
    var sock = getSocketFromFD(fd);
    if (!sock.daddr) {
      return -53;
    }
    // The socket is not connected.
    var errno = writeSockaddr(addr, sock.family, DNS.lookup_name(sock.daddr), sock.dport, addrlen);
    return 0;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_getsockopt(fd, level, optname, optval, optlen, d1) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(7, 0, 1, fd, level, optname, optval, optlen, d1);
  try {
    var sock = getSocketFromFD(fd);
    // Minimal getsockopt aimed at resolving https://github.com/emscripten-core/emscripten/issues/2211
    // so only supports SOL_SOCKET with SO_ERROR.
    if (level === 1) {
      if (optname === 4) {
        GROWABLE_HEAP_I32()[((optval) >> 2)] = sock.error;
        GROWABLE_HEAP_I32()[((optlen) >> 2)] = 4;
        sock.error = null;
        // Clear the error (The SO_ERROR option obtains and then clears this field).
        return 0;
      }
    }
    return -50;
  } // The option is unknown at the level indicated.
  catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_ioctl(fd, op, varargs) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(8, 0, 1, fd, op, varargs);
  SYSCALLS.varargs = varargs;
  try {
    var stream = SYSCALLS.getStreamFromFD(fd);
    switch (op) {
     case 21509:
      {
        if (!stream.tty) return -59;
        return 0;
      }

     case 21505:
      {
        if (!stream.tty) return -59;
        if (stream.tty.ops.ioctl_tcgets) {
          var termios = stream.tty.ops.ioctl_tcgets(stream);
          var argp = syscallGetVarargP();
          GROWABLE_HEAP_I32()[((argp) >> 2)] = termios.c_iflag || 0;
          GROWABLE_HEAP_I32()[(((argp) + (4)) >> 2)] = termios.c_oflag || 0;
          GROWABLE_HEAP_I32()[(((argp) + (8)) >> 2)] = termios.c_cflag || 0;
          GROWABLE_HEAP_I32()[(((argp) + (12)) >> 2)] = termios.c_lflag || 0;
          for (var i = 0; i < 32; i++) {
            GROWABLE_HEAP_I8()[(argp + i) + (17)] = termios.c_cc[i] || 0;
          }
          return 0;
        }
        return 0;
      }

     case 21510:
     case 21511:
     case 21512:
      {
        if (!stream.tty) return -59;
        return 0;
      }

     // no-op, not actually adjusting terminal settings
      case 21506:
     case 21507:
     case 21508:
      {
        if (!stream.tty) return -59;
        if (stream.tty.ops.ioctl_tcsets) {
          var argp = syscallGetVarargP();
          var c_iflag = GROWABLE_HEAP_I32()[((argp) >> 2)];
          var c_oflag = GROWABLE_HEAP_I32()[(((argp) + (4)) >> 2)];
          var c_cflag = GROWABLE_HEAP_I32()[(((argp) + (8)) >> 2)];
          var c_lflag = GROWABLE_HEAP_I32()[(((argp) + (12)) >> 2)];
          var c_cc = [];
          for (var i = 0; i < 32; i++) {
            c_cc.push(GROWABLE_HEAP_I8()[(argp + i) + (17)]);
          }
          return stream.tty.ops.ioctl_tcsets(stream.tty, op, {
            c_iflag,
            c_oflag,
            c_cflag,
            c_lflag,
            c_cc
          });
        }
        return 0;
      }

     // no-op, not actually adjusting terminal settings
      case 21519:
      {
        if (!stream.tty) return -59;
        var argp = syscallGetVarargP();
        GROWABLE_HEAP_I32()[((argp) >> 2)] = 0;
        return 0;
      }

     case 21520:
      {
        if (!stream.tty) return -59;
        return -28;
      }

     // not supported
      case 21531:
      {
        var argp = syscallGetVarargP();
        return FS.ioctl(stream, op, argp);
      }

     case 21523:
      {
        // TODO: in theory we should write to the winsize struct that gets
        // passed in, but for now musl doesn't read anything on it
        if (!stream.tty) return -59;
        if (stream.tty.ops.ioctl_tiocgwinsz) {
          var winsize = stream.tty.ops.ioctl_tiocgwinsz(stream.tty);
          var argp = syscallGetVarargP();
          GROWABLE_HEAP_I16()[((argp) >> 1)] = winsize[0];
          GROWABLE_HEAP_I16()[(((argp) + (2)) >> 1)] = winsize[1];
        }
        return 0;
      }

     case 21524:
      {
        // TODO: technically, this ioctl call should change the window size.
        // but, since emscripten doesn't have any concept of a terminal window
        // yet, we'll just silently throw it away as we do TIOCGWINSZ
        if (!stream.tty) return -59;
        return 0;
      }

     case 21515:
      {
        if (!stream.tty) return -59;
        return 0;
      }

     default:
      return -28;
    }
  } // not supported
  catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_lstat64(path, buf) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(9, 0, 1, path, buf);
  try {
    path = SYSCALLS.getStr(path);
    return SYSCALLS.doStat(FS.lstat, path, buf);
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_newfstatat(dirfd, path, buf, flags) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(10, 0, 1, dirfd, path, buf, flags);
  try {
    path = SYSCALLS.getStr(path);
    var nofollow = flags & 256;
    var allowEmpty = flags & 4096;
    flags = flags & (~6400);
    path = SYSCALLS.calculateAt(dirfd, path, allowEmpty);
    return SYSCALLS.doStat(nofollow ? FS.lstat : FS.stat, path, buf);
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_openat(dirfd, path, flags, varargs) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(11, 0, 1, dirfd, path, flags, varargs);
  SYSCALLS.varargs = varargs;
  try {
    path = SYSCALLS.getStr(path);
    path = SYSCALLS.calculateAt(dirfd, path);
    var mode = varargs ? syscallGetVarargI() : 0;
    return FS.open(path, flags, mode).fd;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_poll(fds, nfds, timeout) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(12, 0, 1, fds, nfds, timeout);
  try {
    var nonzero = 0;
    for (var i = 0; i < nfds; i++) {
      var pollfd = fds + 8 * i;
      var fd = GROWABLE_HEAP_I32()[((pollfd) >> 2)];
      var events = GROWABLE_HEAP_I16()[(((pollfd) + (4)) >> 1)];
      var mask = 32;
      var stream = FS.getStream(fd);
      if (stream) {
        mask = SYSCALLS.DEFAULT_POLLMASK;
        if (stream.stream_ops.poll) {
          mask = stream.stream_ops.poll(stream, -1);
        }
      }
      mask &= events | 8 | 16;
      if (mask) nonzero++;
      GROWABLE_HEAP_I16()[(((pollfd) + (6)) >> 1)] = mask;
    }
    return nonzero;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_recvfrom(fd, buf, len, flags, addr, addrlen) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(13, 0, 1, fd, buf, len, flags, addr, addrlen);
  try {
    var sock = getSocketFromFD(fd);
    var msg = sock.sock_ops.recvmsg(sock, len);
    if (!msg) return 0;
    // socket is closed
    if (addr) {
      var errno = writeSockaddr(addr, sock.family, DNS.lookup_name(msg.addr), msg.port, addrlen);
    }
    GROWABLE_HEAP_U8().set(msg.buffer, buf);
    return msg.buffer.byteLength;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_sendto(fd, message, length, flags, addr, addr_len) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(14, 0, 1, fd, message, length, flags, addr, addr_len);
  try {
    var sock = getSocketFromFD(fd);
    if (!addr) {
      // send, no address provided
      return FS.write(sock.stream, GROWABLE_HEAP_I8(), message, length);
    }
    var dest = getSocketAddress(addr, addr_len);
    // sendto an address
    return sock.sock_ops.sendmsg(sock, GROWABLE_HEAP_I8(), message, length, dest.addr, dest.port);
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_socket(domain, type, protocol) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(15, 0, 1, domain, type, protocol);
  try {
    var sock = SOCKFS.createSocket(domain, type, protocol);
    return sock.stream.fd;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_stat64(path, buf) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(16, 0, 1, path, buf);
  try {
    path = SYSCALLS.getStr(path);
    return SYSCALLS.doStat(FS.stat, path, buf);
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

var __abort_js = () => abort("");

var nowIsMonotonic = 1;

var __emscripten_get_now_is_monotonic = () => nowIsMonotonic;

var __emscripten_init_main_thread_js = tb => {
  // Pass the thread address to the native code where they stored in wasm
  // globals which act as a form of TLS. Global constructors trying
  // to access this value will read the wrong value, but that is UB anyway.
  __emscripten_thread_init(tb, /*is_main=*/ !ENVIRONMENT_IS_WORKER, /*is_runtime=*/ 1, /*can_block=*/ !ENVIRONMENT_IS_WEB, /*default_stacksize=*/ 8388608, /*start_profiling=*/ false);
  PThread.threadInitTLS();
};

var maybeExit = () => {
  if (!keepRuntimeAlive()) {
    try {
      if (ENVIRONMENT_IS_PTHREAD) __emscripten_thread_exit(EXITSTATUS); else _exit(EXITSTATUS);
    } catch (e) {
      handleException(e);
    }
  }
};

var callUserCallback = func => {
  if (ABORT) {
    return;
  }
  try {
    func();
    maybeExit();
  } catch (e) {
    handleException(e);
  }
};

var __emscripten_thread_mailbox_await = pthread_ptr => {
  if (typeof Atomics.waitAsync === "function") {
    // Wait on the pthread's initial self-pointer field because it is easy and
    // safe to access from sending threads that need to notify the waiting
    // thread.
    // TODO: How to make this work with wasm64?
    var wait = Atomics.waitAsync(GROWABLE_HEAP_I32(), ((pthread_ptr) >> 2), pthread_ptr);
    wait.value.then(checkMailbox);
    var waitingAsync = pthread_ptr + 128;
    Atomics.store(GROWABLE_HEAP_I32(), ((waitingAsync) >> 2), 1);
  }
};

// If `Atomics.waitAsync` is not implemented, then we will always fall back
// to postMessage and there is no need to do anything here.
var checkMailbox = () => {
  // Only check the mailbox if we have a live pthread runtime. We implement
  // pthread_self to return 0 if there is no live runtime.
  var pthread_ptr = _pthread_self();
  if (pthread_ptr) {
    // If we are using Atomics.waitAsync as our notification mechanism, wait
    // for a notification before processing the mailbox to avoid missing any
    // work that could otherwise arrive after we've finished processing the
    // mailbox and before we're ready for the next notification.
    __emscripten_thread_mailbox_await(pthread_ptr);
    callUserCallback(__emscripten_check_mailbox);
  }
};

var __emscripten_notify_mailbox_postmessage = (targetThread, currThreadId) => {
  if (targetThread == currThreadId) {
    setTimeout(checkMailbox);
  } else if (ENVIRONMENT_IS_PTHREAD) {
    postMessage({
      targetThread,
      cmd: "checkMailbox"
    });
  } else {
    var worker = PThread.pthreads[targetThread];
    if (!worker) {
      return;
    }
    worker.postMessage({
      cmd: "checkMailbox"
    });
  }
};

var proxiedJSCallArgs = [];

var __emscripten_receive_on_main_thread_js = (funcIndex, emAsmAddr, callingThread, numCallArgs, args) => {
  // Sometimes we need to backproxy events to the calling thread (e.g.
  // HTML5 DOM events handlers such as
  // emscripten_set_mousemove_callback()), so keep track in a globally
  // accessible variable about the thread that initiated the proxying.
  proxiedJSCallArgs.length = numCallArgs;
  var b = ((args) >> 3);
  for (var i = 0; i < numCallArgs; i++) {
    proxiedJSCallArgs[i] = GROWABLE_HEAP_F64()[b + i];
  }
  // Proxied JS library funcs use funcIndex and EM_ASM functions use emAsmAddr
  var func = proxiedFunctionTable[funcIndex];
  PThread.currentProxiedOperationCallerThread = callingThread;
  var rtn = func(...proxiedJSCallArgs);
  PThread.currentProxiedOperationCallerThread = 0;
  return rtn;
};

var __emscripten_runtime_keepalive_clear = () => {
  noExitRuntime = false;
  runtimeKeepaliveCounter = 0;
};

var __emscripten_thread_cleanup = thread => {
  // Called when a thread needs to be cleaned up so it can be reused.
  // A thread is considered reusable when it either returns from its
  // entry point, calls pthread_exit, or acts upon a cancellation.
  // Detached threads are responsible for calling this themselves,
  // otherwise pthread_join is responsible for calling this.
  if (!ENVIRONMENT_IS_PTHREAD) cleanupThread(thread); else postMessage({
    cmd: "cleanupThread",
    thread
  });
};

var __emscripten_thread_set_strongref = thread => {
  // Called when a thread needs to be strongly referenced.
  // Currently only used for:
  // - keeping the "main" thread alive in PROXY_TO_PTHREAD mode;
  // - crashed threads that needs to propagate the uncaught exception
  //   back to the main thread.
  if (ENVIRONMENT_IS_NODE) {
    PThread.pthreads[thread].ref();
  }
};

var timers = {};

var _emscripten_get_now = () => performance.timeOrigin + performance.now();

function __setitimer_js(which, timeout_ms) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(17, 0, 1, which, timeout_ms);
  // First, clear any existing timer.
  if (timers[which]) {
    clearTimeout(timers[which].id);
    delete timers[which];
  }
  // A timeout of zero simply cancels the current timeout so we have nothing
  // more to do.
  if (!timeout_ms) return 0;
  var id = setTimeout(() => {
    delete timers[which];
    callUserCallback(() => __emscripten_timeout(which, _emscripten_get_now()));
  }, timeout_ms);
  timers[which] = {
    id,
    timeout_ms
  };
  return 0;
}

var warnOnce = text => {
  warnOnce.shown ||= {};
  if (!warnOnce.shown[text]) {
    warnOnce.shown[text] = 1;
    if (ENVIRONMENT_IS_NODE) text = "warning: " + text;
    err(text);
  }
};

var _emscripten_check_blocking_allowed = () => {};

var _emscripten_date_now = () => Date.now();

var runtimeKeepalivePush = () => {
  runtimeKeepaliveCounter += 1;
};

var _emscripten_exit_with_live_runtime = () => {
  runtimeKeepalivePush();
  throw "unwind";
};

var getHeapMax = () => // Stay one Wasm page short of 4GB: while e.g. Chrome is able to allocate
// full 4GB Wasm memories, the size will wrap back to 0 bytes in Wasm side
// for any code that deals with heap sizes, which would require special
// casing all heap size related code to treat 0 specially.
2147483648;

var _emscripten_get_heap_max = () => getHeapMax();

var _emscripten_num_logical_cores = () => ENVIRONMENT_IS_NODE ? require("os").cpus().length : navigator["hardwareConcurrency"];

var abortOnCannotGrowMemory = requestedSize => {
  abort("OOM");
};

var growMemory = size => {
  var b = wasmMemory.buffer;
  var pages = ((size - b.byteLength + 65535) / 65536) | 0;
  try {
    // round size grow request up to wasm page size (fixed 64KB per spec)
    wasmMemory.grow(pages);
    // .grow() takes a delta compared to the previous size
    updateMemoryViews();
    return 1;
  } /*success*/ catch (e) {}
};

// implicit 0 return to save code size (caller will cast "undefined" into 0
// anyhow)
var _emscripten_resize_heap = requestedSize => {
  var oldSize = GROWABLE_HEAP_U8().length;
  // With CAN_ADDRESS_2GB or MEMORY64, pointers are already unsigned.
  requestedSize >>>= 0;
  // With multithreaded builds, races can happen (another thread might increase the size
  // in between), so return a failure, and let the caller retry.
  if (requestedSize <= oldSize) {
    return false;
  }
  // Memory resize rules:
  // 1.  Always increase heap size to at least the requested size, rounded up
  //     to next page multiple.
  // 2a. If MEMORY_GROWTH_LINEAR_STEP == -1, excessively resize the heap
  //     geometrically: increase the heap size according to
  //     MEMORY_GROWTH_GEOMETRIC_STEP factor (default +20%), At most
  //     overreserve by MEMORY_GROWTH_GEOMETRIC_CAP bytes (default 96MB).
  // 2b. If MEMORY_GROWTH_LINEAR_STEP != -1, excessively resize the heap
  //     linearly: increase the heap size by at least
  //     MEMORY_GROWTH_LINEAR_STEP bytes.
  // 3.  Max size for the heap is capped at 2048MB-WASM_PAGE_SIZE, or by
  //     MAXIMUM_MEMORY, or by ASAN limit, depending on which is smallest
  // 4.  If we were unable to allocate as much memory, it may be due to
  //     over-eager decision to excessively reserve due to (3) above.
  //     Hence if an allocation fails, cut down on the amount of excess
  //     growth, in an attempt to succeed to perform a smaller allocation.
  // A limit is set for how much we can grow. We should not exceed that
  // (the wasm binary specifies it, so if we tried, we'd fail anyhow).
  var maxHeapSize = getHeapMax();
  if (requestedSize > maxHeapSize) {
    abortOnCannotGrowMemory(requestedSize);
  }
  // Loop through potential heap size increases. If we attempt a too eager
  // reservation that fails, cut down on the attempted size and reserve a
  // smaller bump instead. (max 3 times, chosen somewhat arbitrarily)
  for (var cutDown = 1; cutDown <= 4; cutDown *= 2) {
    var overGrownHeapSize = oldSize * (1 + .2 / cutDown);
    // ensure geometric growth
    // but limit overreserving (default to capping at +96MB overgrowth at most)
    overGrownHeapSize = Math.min(overGrownHeapSize, requestedSize + 100663296);
    var newSize = Math.min(maxHeapSize, alignMemory(Math.max(requestedSize, overGrownHeapSize), 65536));
    var replacement = growMemory(newSize);
    if (replacement) {
      return true;
    }
  }
  abortOnCannotGrowMemory(requestedSize);
};

var ENV = {};

var getExecutableName = () => thisProgram || "./this.program";

var getEnvStrings = () => {
  if (!getEnvStrings.strings) {
    // Default values.
    // Browser language detection #8751
    var lang = ((typeof navigator == "object" && navigator.languages && navigator.languages[0]) || "C").replace("-", "_") + ".UTF-8";
    var env = {
      "USER": "web_user",
      "LOGNAME": "web_user",
      "PATH": "/",
      "PWD": "/",
      "HOME": "/home/web_user",
      "LANG": lang,
      "_": getExecutableName()
    };
    // Apply the user-provided values, if any.
    for (var x in ENV) {
      // x is a key in ENV; if ENV[x] is undefined, that means it was
      // explicitly set to be so. We allow user code to do that to
      // force variables with default values to remain unset.
      if (ENV[x] === undefined) delete env[x]; else env[x] = ENV[x];
    }
    var strings = [];
    for (var x in env) {
      strings.push(`${x}=${env[x]}`);
    }
    getEnvStrings.strings = strings;
  }
  return getEnvStrings.strings;
};

var stringToAscii = (str, buffer) => {
  for (var i = 0; i < str.length; ++i) {
    GROWABLE_HEAP_I8()[buffer++] = str.charCodeAt(i);
  }
  // Null-terminate the string
  GROWABLE_HEAP_I8()[buffer] = 0;
};

var _environ_get = function(__environ, environ_buf) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(18, 0, 1, __environ, environ_buf);
  var bufSize = 0;
  getEnvStrings().forEach((string, i) => {
    var ptr = environ_buf + bufSize;
    GROWABLE_HEAP_U32()[(((__environ) + (i * 4)) >> 2)] = ptr;
    stringToAscii(string, ptr);
    bufSize += string.length + 1;
  });
  return 0;
};

var _environ_sizes_get = function(penviron_count, penviron_buf_size) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(19, 0, 1, penviron_count, penviron_buf_size);
  var strings = getEnvStrings();
  GROWABLE_HEAP_U32()[((penviron_count) >> 2)] = strings.length;
  var bufSize = 0;
  strings.forEach(string => bufSize += string.length + 1);
  GROWABLE_HEAP_U32()[((penviron_buf_size) >> 2)] = bufSize;
  return 0;
};

function _fd_close(fd) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(20, 0, 1, fd);
  try {
    var stream = SYSCALLS.getStreamFromFD(fd);
    FS.close(stream);
    return 0;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return e.errno;
  }
}

function _fd_fdstat_get(fd, pbuf) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(21, 0, 1, fd, pbuf);
  try {
    var rightsBase = 0;
    var rightsInheriting = 0;
    var flags = 0;
    {
      var stream = SYSCALLS.getStreamFromFD(fd);
      // All character devices are terminals (other things a Linux system would
      // assume is a character device, like the mouse, we have special APIs for).
      var type = stream.tty ? 2 : FS.isDir(stream.mode) ? 3 : FS.isLink(stream.mode) ? 7 : 4;
    }
    GROWABLE_HEAP_I8()[pbuf] = type;
    GROWABLE_HEAP_I16()[(((pbuf) + (2)) >> 1)] = flags;
    (tempI64 = [ rightsBase >>> 0, (tempDouble = rightsBase, (+(Math.abs(tempDouble))) >= 1 ? (tempDouble > 0 ? (+(Math.floor((tempDouble) / 4294967296))) >>> 0 : (~~((+(Math.ceil((tempDouble - +(((~~(tempDouble))) >>> 0)) / 4294967296))))) >>> 0) : 0) ], 
    GROWABLE_HEAP_I32()[(((pbuf) + (8)) >> 2)] = tempI64[0], GROWABLE_HEAP_I32()[(((pbuf) + (12)) >> 2)] = tempI64[1]);
    (tempI64 = [ rightsInheriting >>> 0, (tempDouble = rightsInheriting, (+(Math.abs(tempDouble))) >= 1 ? (tempDouble > 0 ? (+(Math.floor((tempDouble) / 4294967296))) >>> 0 : (~~((+(Math.ceil((tempDouble - +(((~~(tempDouble))) >>> 0)) / 4294967296))))) >>> 0) : 0) ], 
    GROWABLE_HEAP_I32()[(((pbuf) + (16)) >> 2)] = tempI64[0], GROWABLE_HEAP_I32()[(((pbuf) + (20)) >> 2)] = tempI64[1]);
    return 0;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return e.errno;
  }
}

/** @param {number=} offset */ var doReadv = (stream, iov, iovcnt, offset) => {
  var ret = 0;
  for (var i = 0; i < iovcnt; i++) {
    var ptr = GROWABLE_HEAP_U32()[((iov) >> 2)];
    var len = GROWABLE_HEAP_U32()[(((iov) + (4)) >> 2)];
    iov += 8;
    var curr = FS.read(stream, GROWABLE_HEAP_I8(), ptr, len, offset);
    if (curr < 0) return -1;
    ret += curr;
    if (curr < len) break;
    // nothing more to read
    if (typeof offset != "undefined") {
      offset += curr;
    }
  }
  return ret;
};

function _fd_read(fd, iov, iovcnt, pnum) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(22, 0, 1, fd, iov, iovcnt, pnum);
  try {
    var stream = SYSCALLS.getStreamFromFD(fd);
    var num = doReadv(stream, iov, iovcnt);
    GROWABLE_HEAP_U32()[((pnum) >> 2)] = num;
    return 0;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return e.errno;
  }
}

function _fd_seek(fd, offset_low, offset_high, whence, newOffset) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(23, 0, 1, fd, offset_low, offset_high, whence, newOffset);
  var offset = convertI32PairToI53Checked(offset_low, offset_high);
  try {
    if (isNaN(offset)) return 61;
    var stream = SYSCALLS.getStreamFromFD(fd);
    FS.llseek(stream, offset, whence);
    (tempI64 = [ stream.position >>> 0, (tempDouble = stream.position, (+(Math.abs(tempDouble))) >= 1 ? (tempDouble > 0 ? (+(Math.floor((tempDouble) / 4294967296))) >>> 0 : (~~((+(Math.ceil((tempDouble - +(((~~(tempDouble))) >>> 0)) / 4294967296))))) >>> 0) : 0) ], 
    GROWABLE_HEAP_I32()[((newOffset) >> 2)] = tempI64[0], GROWABLE_HEAP_I32()[(((newOffset) + (4)) >> 2)] = tempI64[1]);
    if (stream.getdents && offset === 0 && whence === 0) stream.getdents = null;
    // reset readdir state
    return 0;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return e.errno;
  }
}

/** @param {number=} offset */ var doWritev = (stream, iov, iovcnt, offset) => {
  var ret = 0;
  for (var i = 0; i < iovcnt; i++) {
    var ptr = GROWABLE_HEAP_U32()[((iov) >> 2)];
    var len = GROWABLE_HEAP_U32()[(((iov) + (4)) >> 2)];
    iov += 8;
    var curr = FS.write(stream, GROWABLE_HEAP_I8(), ptr, len, offset);
    if (curr < 0) return -1;
    ret += curr;
    if (curr < len) {
      // No more space to write.
      break;
    }
    if (typeof offset != "undefined") {
      offset += curr;
    }
  }
  return ret;
};

function _fd_write(fd, iov, iovcnt, pnum) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(24, 0, 1, fd, iov, iovcnt, pnum);
  try {
    var stream = SYSCALLS.getStreamFromFD(fd);
    var num = doWritev(stream, iov, iovcnt);
    GROWABLE_HEAP_U32()[((pnum) >> 2)] = num;
    return 0;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return e.errno;
  }
}

function _getaddrinfo(node, service, hint, out) {
  if (ENVIRONMENT_IS_PTHREAD) return proxyToMainThread(25, 0, 1, node, service, hint, out);
  // Note getaddrinfo currently only returns a single addrinfo with ai_next defaulting to NULL. When NULL
  // hints are specified or ai_family set to AF_UNSPEC or ai_socktype or ai_protocol set to 0 then we
  // really should provide a linked list of suitable addrinfo values.
  var addrs = [];
  var canon = null;
  var addr = 0;
  var port = 0;
  var flags = 0;
  var family = 0;
  var type = 0;
  var proto = 0;
  var ai, last;
  function allocaddrinfo(family, type, proto, canon, addr, port) {
    var sa, salen, ai;
    var errno;
    salen = family === 10 ? 28 : 16;
    addr = family === 10 ? inetNtop6(addr) : inetNtop4(addr);
    sa = _malloc(salen);
    errno = writeSockaddr(sa, family, addr, port);
    assert(!errno);
    ai = _malloc(32);
    GROWABLE_HEAP_I32()[(((ai) + (4)) >> 2)] = family;
    GROWABLE_HEAP_I32()[(((ai) + (8)) >> 2)] = type;
    GROWABLE_HEAP_I32()[(((ai) + (12)) >> 2)] = proto;
    GROWABLE_HEAP_U32()[(((ai) + (24)) >> 2)] = canon;
    GROWABLE_HEAP_U32()[(((ai) + (20)) >> 2)] = sa;
    if (family === 10) {
      GROWABLE_HEAP_I32()[(((ai) + (16)) >> 2)] = 28;
    } else {
      GROWABLE_HEAP_I32()[(((ai) + (16)) >> 2)] = 16;
    }
    GROWABLE_HEAP_I32()[(((ai) + (28)) >> 2)] = 0;
    return ai;
  }
  if (hint) {
    flags = GROWABLE_HEAP_I32()[((hint) >> 2)];
    family = GROWABLE_HEAP_I32()[(((hint) + (4)) >> 2)];
    type = GROWABLE_HEAP_I32()[(((hint) + (8)) >> 2)];
    proto = GROWABLE_HEAP_I32()[(((hint) + (12)) >> 2)];
  }
  if (type && !proto) {
    proto = type === 2 ? 17 : 6;
  }
  if (!type && proto) {
    type = proto === 17 ? 2 : 1;
  }
  // If type or proto are set to zero in hints we should really be returning multiple addrinfo values, but for
  // now default to a TCP STREAM socket so we can at least return a sensible addrinfo given NULL hints.
  if (proto === 0) {
    proto = 6;
  }
  if (type === 0) {
    type = 1;
  }
  if (!node && !service) {
    return -2;
  }
  if (flags & ~(1 | 2 | 4 | 1024 | 8 | 16 | 32)) {
    return -1;
  }
  if (hint !== 0 && (GROWABLE_HEAP_I32()[((hint) >> 2)] & 2) && !node) {
    return -1;
  }
  if (flags & 32) {
    // TODO
    return -2;
  }
  if (type !== 0 && type !== 1 && type !== 2) {
    return -7;
  }
  if (family !== 0 && family !== 2 && family !== 10) {
    return -6;
  }
  if (service) {
    service = UTF8ToString(service);
    port = parseInt(service, 10);
    if (isNaN(port)) {
      if (flags & 1024) {
        return -2;
      }
      // TODO support resolving well-known service names from:
      // http://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.txt
      return -8;
    }
  }
  if (!node) {
    if (family === 0) {
      family = 2;
    }
    if ((flags & 1) === 0) {
      if (family === 2) {
        addr = _htonl(2130706433);
      } else {
        addr = [ 0, 0, 0, _htonl(1) ];
      }
    }
    ai = allocaddrinfo(family, type, proto, null, addr, port);
    GROWABLE_HEAP_U32()[((out) >> 2)] = ai;
    return 0;
  }
  // try as a numeric address
  node = UTF8ToString(node);
  addr = inetPton4(node);
  if (addr !== null) {
    // incoming node is a valid ipv4 address
    if (family === 0 || family === 2) {
      family = 2;
    } else if (family === 10 && (flags & 8)) {
      addr = [ 0, 0, _htonl(65535), addr ];
      family = 10;
    } else {
      return -2;
    }
  } else {
    addr = inetPton6(node);
    if (addr !== null) {
      // incoming node is a valid ipv6 address
      if (family === 0 || family === 10) {
        family = 10;
      } else {
        return -2;
      }
    }
  }
  if (addr != null) {
    ai = allocaddrinfo(family, type, proto, node, addr, port);
    GROWABLE_HEAP_U32()[((out) >> 2)] = ai;
    return 0;
  }
  if (flags & 4) {
    return -2;
  }
  // try as a hostname
  // resolve the hostname to a temporary fake address
  node = DNS.lookup_name(node);
  addr = inetPton4(node);
  if (family === 0) {
    family = 2;
  } else if (family === 10) {
    addr = [ 0, 0, _htonl(65535), addr ];
  }
  ai = allocaddrinfo(family, type, proto, null, addr, port);
  GROWABLE_HEAP_U32()[((out) >> 2)] = ai;
  return 0;
}

function _random_get(buffer, size) {
  try {
    randomFill(GROWABLE_HEAP_U8().subarray(buffer, buffer + size));
    return 0;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return e.errno;
  }
}

var getCFunc = ident => {
  var func = Module["_" + ident];
  // closure exported function
  return func;
};

var writeArrayToMemory = (array, buffer) => {
  GROWABLE_HEAP_I8().set(array, buffer);
};

var stringToUTF8 = (str, outPtr, maxBytesToWrite) => stringToUTF8Array(str, GROWABLE_HEAP_U8(), outPtr, maxBytesToWrite);

var stringToUTF8OnStack = str => {
  var size = lengthBytesUTF8(str) + 1;
  var ret = stackAlloc(size);
  stringToUTF8(str, ret, size);
  return ret;
};

/**
     * @param {string|null=} returnType
     * @param {Array=} argTypes
     * @param {Arguments|Array=} args
     * @param {Object=} opts
     */ var ccall = (ident, returnType, argTypes, args, opts) => {
  // For fast lookup of conversion functions
  var toC = {
    "string": str => {
      var ret = 0;
      if (str !== null && str !== undefined && str !== 0) {
        // null string
        ret = stringToUTF8OnStack(str);
      }
      return ret;
    },
    "array": arr => {
      var ret = stackAlloc(arr.length);
      writeArrayToMemory(arr, ret);
      return ret;
    }
  };
  function convertReturnValue(ret) {
    if (returnType === "string") {
      return UTF8ToString(ret);
    }
    if (returnType === "boolean") return Boolean(ret);
    return ret;
  }
  var func = getCFunc(ident);
  var cArgs = [];
  var stack = 0;
  if (args) {
    for (var i = 0; i < args.length; i++) {
      var converter = toC[argTypes[i]];
      if (converter) {
        if (stack === 0) stack = stackSave();
        cArgs[i] = converter(args[i]);
      } else {
        cArgs[i] = args[i];
      }
    }
  }
  var ret = func(...cArgs);
  function onDone(ret) {
    if (stack !== 0) stackRestore(stack);
    return convertReturnValue(ret);
  }
  ret = onDone(ret);
  return ret;
};

/**
     * @param {string=} returnType
     * @param {Array=} argTypes
     * @param {Object=} opts
     */ var cwrap = (ident, returnType, argTypes, opts) => {
  // When the function takes numbers and returns a number, we can just return
  // the original function
  var numericArgs = !argTypes || argTypes.every(type => type === "number" || type === "boolean");
  var numericRet = returnType !== "string";
  if (numericRet && numericArgs && !opts) {
    return getCFunc(ident);
  }
  return (...args) => ccall(ident, returnType, argTypes, args, opts);
};

var stringToNewUTF8 = str => {
  var size = lengthBytesUTF8(str) + 1;
  var ret = _malloc(size);
  if (ret) stringToUTF8(str, ret, size);
  return ret;
};

var uleb128Encode = (n, target) => {
  if (n < 128) {
    target.push(n);
  } else {
    target.push((n % 128) | 128, n >> 7);
  }
};

var sigToWasmTypes = sig => {
  var typeNames = {
    "i": "i32",
    "j": "i64",
    "f": "f32",
    "d": "f64",
    "e": "externref",
    "p": "i32"
  };
  var type = {
    parameters: [],
    results: sig[0] == "v" ? [] : [ typeNames[sig[0]] ]
  };
  for (var i = 1; i < sig.length; ++i) {
    type.parameters.push(typeNames[sig[i]]);
  }
  return type;
};

var generateFuncType = (sig, target) => {
  var sigRet = sig.slice(0, 1);
  var sigParam = sig.slice(1);
  var typeCodes = {
    "i": 127,
    // i32
    "p": 127,
    // i32
    "j": 126,
    // i64
    "f": 125,
    // f32
    "d": 124,
    // f64
    "e": 111
  };
  // Parameters, length + signatures
  target.push(96);
  /* form: func */ uleb128Encode(sigParam.length, target);
  for (var i = 0; i < sigParam.length; ++i) {
    target.push(typeCodes[sigParam[i]]);
  }
  // Return values, length + signatures
  // With no multi-return in MVP, either 0 (void) or 1 (anything else)
  if (sigRet == "v") {
    target.push(0);
  } else {
    target.push(1, typeCodes[sigRet]);
  }
};

var convertJsFunctionToWasm = (func, sig) => {
  // If the type reflection proposal is available, use the new
  // "WebAssembly.Function" constructor.
  // Otherwise, construct a minimal wasm module importing the JS function and
  // re-exporting it.
  if (typeof WebAssembly.Function == "function") {
    return new WebAssembly.Function(sigToWasmTypes(sig), func);
  }
  // The module is static, with the exception of the type section, which is
  // generated based on the signature passed in.
  var typeSectionBody = [ 1 ];
  // count: 1
  generateFuncType(sig, typeSectionBody);
  // Rest of the module is static
  var bytes = [ 0, 97, 115, 109, // magic ("\0asm")
  1, 0, 0, 0, // version: 1
  1 ];
  // Write the overall length of the type section followed by the body
  uleb128Encode(typeSectionBody.length, bytes);
  bytes.push(...typeSectionBody);
  // The rest of the module is static
  bytes.push(2, 7, // import section
  // (import "e" "f" (func 0 (type 0)))
  1, 1, 101, 1, 102, 0, 0, 7, 5, // export section
  // (export "f" (func 0 (type 0)))
  1, 1, 102, 0, 0);
  // We can compile this wasm module synchronously because it is very small.
  // This accepts an import (at "e.f"), that it reroutes to an export (at "f")
  var module = new WebAssembly.Module(new Uint8Array(bytes));
  var instance = new WebAssembly.Instance(module, {
    "e": {
      "f": func
    }
  });
  var wrappedFunc = instance.exports["f"];
  return wrappedFunc;
};

var updateTableMap = (offset, count) => {
  if (functionsInTableMap) {
    for (var i = offset; i < offset + count; i++) {
      var item = getWasmTableEntry(i);
      // Ignore null values.
      if (item) {
        functionsInTableMap.set(item, i);
      }
    }
  }
};

var functionsInTableMap;

var getFunctionAddress = func => {
  // First, create the map if this is the first use.
  if (!functionsInTableMap) {
    functionsInTableMap = new WeakMap;
    updateTableMap(0, wasmTable.length);
  }
  return functionsInTableMap.get(func) || 0;
};

var freeTableIndexes = [];

var getEmptyTableSlot = () => {
  // Reuse a free index if there is one, otherwise grow.
  if (freeTableIndexes.length) {
    return freeTableIndexes.pop();
  }
  // Grow the table
  try {
    /** @suppress {checkTypes} */ wasmTable.grow(1);
  } catch (err) {
    if (!(err instanceof RangeError)) {
      throw err;
    }
    throw "Unable to grow wasm table. Set ALLOW_TABLE_GROWTH.";
  }
  return wasmTable.length - 1;
};

var setWasmTableEntry = (idx, func) => {
  /** @suppress {checkTypes} */ wasmTable.set(idx, func);
  // With ABORT_ON_WASM_EXCEPTIONS wasmTable.get is overridden to return wrapped
  // functions so we need to call it here to retrieve the potential wrapper correctly
  // instead of just storing 'func' directly into wasmTableMirror
  /** @suppress {checkTypes} */ wasmTableMirror[idx] = wasmTable.get(idx);
};

/** @param {string=} sig */ var addFunction = (func, sig) => {
  // Check if the function is already in the table, to ensure each function
  // gets a unique index.
  var rtn = getFunctionAddress(func);
  if (rtn) {
    return rtn;
  }
  // It's not in the table, add it now.
  var ret = getEmptyTableSlot();
  // Set the new value.
  try {
    // Attempting to call this with JS function will cause of table.set() to fail
    setWasmTableEntry(ret, func);
  } catch (err) {
    if (!(err instanceof TypeError)) {
      throw err;
    }
    var wrapped = convertJsFunctionToWasm(func, sig);
    setWasmTableEntry(ret, wrapped);
  }
  functionsInTableMap.set(func, ret);
  return ret;
};

var removeFunction = index => {
  functionsInTableMap.delete(getWasmTableEntry(index));
  setWasmTableEntry(index, null);
  freeTableIndexes.push(index);
};

PThread.init();

FS.createPreloadedFile = FS_createPreloadedFile;

FS.staticInit();

// This error may happen quite a bit. To avoid overhead we reuse it (and
// suffer a lack of stack info).
MEMFS.doesNotExistError = new FS.ErrnoError(44);

/** @suppress {checkTypes} */ MEMFS.doesNotExistError.stack = "<generic error, no stack>";

// proxiedFunctionTable specifies the list of functions that can be called
// either synchronously or asynchronously from other threads in postMessage()d
// or internally queued events. This way a pthread in a Worker can synchronously
// access e.g. the DOM on the main thread.
var proxiedFunctionTable = [ _proc_exit, exitOnMainThread, ___syscall_bind, ___syscall_connect, ___syscall_fcntl64, ___syscall_fstat64, ___syscall_getpeername, ___syscall_getsockopt, ___syscall_ioctl, ___syscall_lstat64, ___syscall_newfstatat, ___syscall_openat, ___syscall_poll, ___syscall_recvfrom, ___syscall_sendto, ___syscall_socket, ___syscall_stat64, __setitimer_js, _environ_get, _environ_sizes_get, _fd_close, _fd_fdstat_get, _fd_read, _fd_seek, _fd_write, _getaddrinfo ];

var wasmImports;

function assignWasmImports() {
  wasmImports = {
    /** @export */ __assert_fail: ___assert_fail,
    /** @export */ __call_sighandler: ___call_sighandler,
    /** @export */ __syscall_bind: ___syscall_bind,
    /** @export */ __syscall_connect: ___syscall_connect,
    /** @export */ __syscall_fcntl64: ___syscall_fcntl64,
    /** @export */ __syscall_fstat64: ___syscall_fstat64,
    /** @export */ __syscall_getpeername: ___syscall_getpeername,
    /** @export */ __syscall_getsockopt: ___syscall_getsockopt,
    /** @export */ __syscall_ioctl: ___syscall_ioctl,
    /** @export */ __syscall_lstat64: ___syscall_lstat64,
    /** @export */ __syscall_newfstatat: ___syscall_newfstatat,
    /** @export */ __syscall_openat: ___syscall_openat,
    /** @export */ __syscall_poll: ___syscall_poll,
    /** @export */ __syscall_recvfrom: ___syscall_recvfrom,
    /** @export */ __syscall_sendto: ___syscall_sendto,
    /** @export */ __syscall_socket: ___syscall_socket,
    /** @export */ __syscall_stat64: ___syscall_stat64,
    /** @export */ _abort_js: __abort_js,
    /** @export */ _emscripten_get_now_is_monotonic: __emscripten_get_now_is_monotonic,
    /** @export */ _emscripten_init_main_thread_js: __emscripten_init_main_thread_js,
    /** @export */ _emscripten_notify_mailbox_postmessage: __emscripten_notify_mailbox_postmessage,
    /** @export */ _emscripten_receive_on_main_thread_js: __emscripten_receive_on_main_thread_js,
    /** @export */ _emscripten_runtime_keepalive_clear: __emscripten_runtime_keepalive_clear,
    /** @export */ _emscripten_thread_cleanup: __emscripten_thread_cleanup,
    /** @export */ _emscripten_thread_mailbox_await: __emscripten_thread_mailbox_await,
    /** @export */ _emscripten_thread_set_strongref: __emscripten_thread_set_strongref,
    /** @export */ _setitimer_js: __setitimer_js,
    /** @export */ emscripten_check_blocking_allowed: _emscripten_check_blocking_allowed,
    /** @export */ emscripten_date_now: _emscripten_date_now,
    /** @export */ emscripten_exit_with_live_runtime: _emscripten_exit_with_live_runtime,
    /** @export */ emscripten_get_heap_max: _emscripten_get_heap_max,
    /** @export */ emscripten_get_now: _emscripten_get_now,
    /** @export */ emscripten_num_logical_cores: _emscripten_num_logical_cores,
    /** @export */ emscripten_resize_heap: _emscripten_resize_heap,
    /** @export */ environ_get: _environ_get,
    /** @export */ environ_sizes_get: _environ_sizes_get,
    /** @export */ exit: _exit,
    /** @export */ fd_close: _fd_close,
    /** @export */ fd_fdstat_get: _fd_fdstat_get,
    /** @export */ fd_read: _fd_read,
    /** @export */ fd_seek: _fd_seek,
    /** @export */ fd_write: _fd_write,
    /** @export */ getaddrinfo: _getaddrinfo,
    /** @export */ memory: wasmMemory,
    /** @export */ proc_exit: _proc_exit,
    /** @export */ random_get: _random_get
  };
}

var wasmExports = createWasm();

var ___wasm_call_ctors = () => (___wasm_call_ctors = wasmExports["__wasm_call_ctors"])();

var _wasmStart = Module["_wasmStart"] = (a0, a1, a2) => (_wasmStart = Module["_wasmStart"] = wasmExports["wasmStart"])(a0, a1, a2);

var _NimMain = Module["_NimMain"] = () => (_NimMain = Module["_NimMain"] = wasmExports["NimMain"])();

var _startVerifProxy = Module["_startVerifProxy"] = (a0, a1, a2) => (_startVerifProxy = Module["_startVerifProxy"] = wasmExports["startVerifProxy"])(a0, a1, a2);

var _wasmFreeString = Module["_wasmFreeString"] = a0 => (_wasmFreeString = Module["_wasmFreeString"] = wasmExports["wasmFreeString"])(a0);

var _freeNimAllocatedString = Module["_freeNimAllocatedString"] = a0 => (_freeNimAllocatedString = Module["_freeNimAllocatedString"] = wasmExports["freeNimAllocatedString"])(a0);

var _wasmStop = Module["_wasmStop"] = () => (_wasmStop = Module["_wasmStop"] = wasmExports["wasmStop"])();

var _stopVerifProxy = Module["_stopVerifProxy"] = a0 => (_stopVerifProxy = Module["_stopVerifProxy"] = wasmExports["stopVerifProxy"])(a0);

var _freeContext = Module["_freeContext"] = a0 => (_freeContext = Module["_freeContext"] = wasmExports["freeContext"])(a0);

var _wasmCall = Module["_wasmCall"] = (a0, a1, a2, a3) => (_wasmCall = Module["_wasmCall"] = wasmExports["wasmCall"])(a0, a1, a2, a3);

var _proxyCall = Module["_proxyCall"] = (a0, a1, a2, a3, a4) => (_proxyCall = Module["_proxyCall"] = wasmExports["proxyCall"])(a0, a1, a2, a3, a4);

var _wasmProcessTasks = Module["_wasmProcessTasks"] = () => (_wasmProcessTasks = Module["_wasmProcessTasks"] = wasmExports["wasmProcessTasks"])();

var _processVerifProxyTasks = Module["_processVerifProxyTasks"] = a0 => (_processVerifProxyTasks = Module["_processVerifProxyTasks"] = wasmExports["processVerifProxyTasks"])(a0);

var _wasmDeliverExecutionTransport = Module["_wasmDeliverExecutionTransport"] = (a0, a1, a2) => (_wasmDeliverExecutionTransport = Module["_wasmDeliverExecutionTransport"] = wasmExports["wasmDeliverExecutionTransport"])(a0, a1, a2);

var _wasmDeliverBeaconTransport = Module["_wasmDeliverBeaconTransport"] = (a0, a1, a2) => (_wasmDeliverBeaconTransport = Module["_wasmDeliverBeaconTransport"] = wasmExports["wasmDeliverBeaconTransport"])(a0, a1, a2);

var _wasmExecCtxUrl = Module["_wasmExecCtxUrl"] = a0 => (_wasmExecCtxUrl = Module["_wasmExecCtxUrl"] = wasmExports["wasmExecCtxUrl"])(a0);

var _wasmExecCtxName = Module["_wasmExecCtxName"] = a0 => (_wasmExecCtxName = Module["_wasmExecCtxName"] = wasmExports["wasmExecCtxName"])(a0);

var _wasmExecCtxParams = Module["_wasmExecCtxParams"] = a0 => (_wasmExecCtxParams = Module["_wasmExecCtxParams"] = wasmExports["wasmExecCtxParams"])(a0);

var _wasmBeaconCtxUrl = Module["_wasmBeaconCtxUrl"] = a0 => (_wasmBeaconCtxUrl = Module["_wasmBeaconCtxUrl"] = wasmExports["wasmBeaconCtxUrl"])(a0);

var _wasmBeaconCtxEndpoint = Module["_wasmBeaconCtxEndpoint"] = a0 => (_wasmBeaconCtxEndpoint = Module["_wasmBeaconCtxEndpoint"] = wasmExports["wasmBeaconCtxEndpoint"])(a0);

var _wasmBeaconCtxParams = Module["_wasmBeaconCtxParams"] = a0 => (_wasmBeaconCtxParams = Module["_wasmBeaconCtxParams"] = wasmExports["wasmBeaconCtxParams"])(a0);

var _malloc = Module["_malloc"] = a0 => (_malloc = Module["_malloc"] = wasmExports["malloc"])(a0);

var _free = Module["_free"] = a0 => (_free = Module["_free"] = wasmExports["free"])(a0);

var __ZN3mcl4bint7get_addEm = Module["__ZN3mcl4bint7get_addEm"] = a0 => (__ZN3mcl4bint7get_addEm = Module["__ZN3mcl4bint7get_addEm"] = wasmExports["_ZN3mcl4bint7get_addEm"])(a0);

var __ZN3mcl4bint7get_subEm = Module["__ZN3mcl4bint7get_subEm"] = a0 => (__ZN3mcl4bint7get_subEm = Module["__ZN3mcl4bint7get_subEm"] = wasmExports["_ZN3mcl4bint7get_subEm"])(a0);

var __ZN3mcl4bint9get_addNFEm = Module["__ZN3mcl4bint9get_addNFEm"] = a0 => (__ZN3mcl4bint9get_addNFEm = Module["__ZN3mcl4bint9get_addNFEm"] = wasmExports["_ZN3mcl4bint9get_addNFEm"])(a0);

var __ZN3mcl4bint9get_subNFEm = Module["__ZN3mcl4bint9get_subNFEm"] = a0 => (__ZN3mcl4bint9get_subNFEm = Module["__ZN3mcl4bint9get_subNFEm"] = wasmExports["_ZN3mcl4bint9get_subNFEm"])(a0);

var __ZN3mcl4bint11get_mulUnitEm = Module["__ZN3mcl4bint11get_mulUnitEm"] = a0 => (__ZN3mcl4bint11get_mulUnitEm = Module["__ZN3mcl4bint11get_mulUnitEm"] = wasmExports["_ZN3mcl4bint11get_mulUnitEm"])(a0);

var __ZN3mcl4bint14get_mulUnitAddEm = Module["__ZN3mcl4bint14get_mulUnitAddEm"] = a0 => (__ZN3mcl4bint14get_mulUnitAddEm = Module["__ZN3mcl4bint14get_mulUnitAddEm"] = wasmExports["_ZN3mcl4bint14get_mulUnitAddEm"])(a0);

var __ZN3mcl4bint7get_mulEm = Module["__ZN3mcl4bint7get_mulEm"] = a0 => (__ZN3mcl4bint7get_mulEm = Module["__ZN3mcl4bint7get_mulEm"] = wasmExports["_ZN3mcl4bint7get_mulEm"])(a0);

var __ZN3mcl4bint7get_sqrEm = Module["__ZN3mcl4bint7get_sqrEm"] = a0 => (__ZN3mcl4bint7get_sqrEm = Module["__ZN3mcl4bint7get_sqrEm"] = wasmExports["_ZN3mcl4bint7get_sqrEm"])(a0);

var __ZN3mcl4bint4shlNEPjPKjjm = Module["__ZN3mcl4bint4shlNEPjPKjjm"] = (a0, a1, a2, a3) => (__ZN3mcl4bint4shlNEPjPKjjm = Module["__ZN3mcl4bint4shlNEPjPKjjm"] = wasmExports["_ZN3mcl4bint4shlNEPjPKjjm"])(a0, a1, a2, a3);

var __ZN3mcl4bint4shrNEPjPKjmm = Module["__ZN3mcl4bint4shrNEPjPKjmm"] = (a0, a1, a2, a3) => (__ZN3mcl4bint4shrNEPjPKjmm = Module["__ZN3mcl4bint4shrNEPjPKjmm"] = wasmExports["_ZN3mcl4bint4shrNEPjPKjmm"])(a0, a1, a2, a3);

var __ZN3mcl4bint9shiftLeftEPjPKjmm = Module["__ZN3mcl4bint9shiftLeftEPjPKjmm"] = (a0, a1, a2, a3) => (__ZN3mcl4bint9shiftLeftEPjPKjmm = Module["__ZN3mcl4bint9shiftLeftEPjPKjmm"] = wasmExports["_ZN3mcl4bint9shiftLeftEPjPKjmm"])(a0, a1, a2, a3);

var __ZN3mcl4bint10shiftRightEPjPKjmm = Module["__ZN3mcl4bint10shiftRightEPjPKjmm"] = (a0, a1, a2, a3) => (__ZN3mcl4bint10shiftRightEPjPKjmm = Module["__ZN3mcl4bint10shiftRightEPjPKjmm"] = wasmExports["_ZN3mcl4bint10shiftRightEPjPKjmm"])(a0, a1, a2, a3);

var __ZN3mcl4bint7addUnitEPjmj = Module["__ZN3mcl4bint7addUnitEPjmj"] = (a0, a1, a2) => (__ZN3mcl4bint7addUnitEPjmj = Module["__ZN3mcl4bint7addUnitEPjmj"] = wasmExports["_ZN3mcl4bint7addUnitEPjmj"])(a0, a1, a2);

var __ZN3mcl4bint7subUnitEPjmj = Module["__ZN3mcl4bint7subUnitEPjmj"] = (a0, a1, a2) => (__ZN3mcl4bint7subUnitEPjmj = Module["__ZN3mcl4bint7subUnitEPjmj"] = wasmExports["_ZN3mcl4bint7subUnitEPjmj"])(a0, a1, a2);

var __ZN3mcl4bint7divUnitEPjPKjmj = Module["__ZN3mcl4bint7divUnitEPjPKjmj"] = (a0, a1, a2, a3) => (__ZN3mcl4bint7divUnitEPjPKjmj = Module["__ZN3mcl4bint7divUnitEPjPKjmj"] = wasmExports["_ZN3mcl4bint7divUnitEPjPKjmj"])(a0, a1, a2, a3);

var __ZN3mcl4bint7modUnitEPKjmj = Module["__ZN3mcl4bint7modUnitEPKjmj"] = (a0, a1, a2) => (__ZN3mcl4bint7modUnitEPKjmj = Module["__ZN3mcl4bint7modUnitEPKjmj"] = wasmExports["_ZN3mcl4bint7modUnitEPKjmj"])(a0, a1, a2);

var __ZN3mcl4bint8divSmallEPjmS1_mPKjm = Module["__ZN3mcl4bint8divSmallEPjmS1_mPKjm"] = (a0, a1, a2, a3, a4, a5) => (__ZN3mcl4bint8divSmallEPjmS1_mPKjm = Module["__ZN3mcl4bint8divSmallEPjmS1_mPKjm"] = wasmExports["_ZN3mcl4bint8divSmallEPjmS1_mPKjm"])(a0, a1, a2, a3, a4, a5);

var __ZN3mcl4bint10divFullBitEPjmS1_mPKjm = Module["__ZN3mcl4bint10divFullBitEPjmS1_mPKjm"] = (a0, a1, a2, a3, a4, a5) => (__ZN3mcl4bint10divFullBitEPjmS1_mPKjm = Module["__ZN3mcl4bint10divFullBitEPjmS1_mPKjm"] = wasmExports["_ZN3mcl4bint10divFullBitEPjmS1_mPKjm"])(a0, a1, a2, a3, a4, a5);

var __ZN3mcl4bint3divEPjmS1_mPKjm = Module["__ZN3mcl4bint3divEPjmS1_mPKjm"] = (a0, a1, a2, a3, a4, a5) => (__ZN3mcl4bint3divEPjmS1_mPKjm = Module["__ZN3mcl4bint3divEPjmS1_mPKjm"] = wasmExports["_ZN3mcl4bint3divEPjmS1_mPKjm"])(a0, a1, a2, a3, a4, a5);

var __ZN3mcl4bint5mulNMEPjPKjmS3_m = Module["__ZN3mcl4bint5mulNMEPjPKjmS3_m"] = (a0, a1, a2, a3, a4) => (__ZN3mcl4bint5mulNMEPjPKjmS3_m = Module["__ZN3mcl4bint5mulNMEPjPKjmS3_m"] = wasmExports["_ZN3mcl4bint5mulNMEPjPKjmS3_m"])(a0, a1, a2, a3, a4);

var __ZN3mcl4bint13mod_SECP256K1EPjPKjS3_ = Module["__ZN3mcl4bint13mod_SECP256K1EPjPKjS3_"] = (a0, a1, a2) => (__ZN3mcl4bint13mod_SECP256K1EPjPKjS3_ = Module["__ZN3mcl4bint13mod_SECP256K1EPjPKjS3_"] = wasmExports["_ZN3mcl4bint13mod_SECP256K1EPjPKjS3_"])(a0, a1, a2);

var __ZN3mcl4bint13mul_SECP256K1EPjPKjS3_S3_ = Module["__ZN3mcl4bint13mul_SECP256K1EPjPKjS3_S3_"] = (a0, a1, a2, a3) => (__ZN3mcl4bint13mul_SECP256K1EPjPKjS3_S3_ = Module["__ZN3mcl4bint13mul_SECP256K1EPjPKjS3_S3_"] = wasmExports["_ZN3mcl4bint13mul_SECP256K1EPjPKjS3_S3_"])(a0, a1, a2, a3);

var __ZN3mcl4bint13sqr_SECP256K1EPjPKjS3_ = Module["__ZN3mcl4bint13sqr_SECP256K1EPjPKjS3_"] = (a0, a1, a2) => (__ZN3mcl4bint13sqr_SECP256K1EPjPKjS3_ = Module["__ZN3mcl4bint13sqr_SECP256K1EPjPKjS3_"] = wasmExports["_ZN3mcl4bint13sqr_SECP256K1EPjPKjS3_"])(a0, a1, a2);

var __ZN3mcl4bint5maskNEPjmm = Module["__ZN3mcl4bint5maskNEPjmm"] = (a0, a1, a2) => (__ZN3mcl4bint5maskNEPjmm = Module["__ZN3mcl4bint5maskNEPjmm"] = wasmExports["_ZN3mcl4bint5maskNEPjmm"])(a0, a1, a2);

var __ZN3mcl2fp5local14hexCharToUint8EPhc = Module["__ZN3mcl2fp5local14hexCharToUint8EPhc"] = (a0, a1) => (__ZN3mcl2fp5local14hexCharToUint8EPhc = Module["__ZN3mcl2fp5local14hexCharToUint8EPhc"] = wasmExports["_ZN3mcl2fp5local14hexCharToUint8EPhc"])(a0, a1);

var __ZN3mcl2fp10arrayToHexEPcmPKjmb = Module["__ZN3mcl2fp10arrayToHexEPcmPKjmb"] = (a0, a1, a2, a3, a4) => (__ZN3mcl2fp10arrayToHexEPcmPKjmb = Module["__ZN3mcl2fp10arrayToHexEPcmPKjmb"] = wasmExports["_ZN3mcl2fp10arrayToHexEPcmPKjmb"])(a0, a1, a2, a3, a4);

var __ZN3mcl2fp10arrayToBinEPcmPKjmb = Module["__ZN3mcl2fp10arrayToBinEPcmPKjmb"] = (a0, a1, a2, a3, a4) => (__ZN3mcl2fp10arrayToBinEPcmPKjmb = Module["__ZN3mcl2fp10arrayToBinEPcmPKjmb"] = wasmExports["_ZN3mcl2fp10arrayToBinEPcmPKjmb"])(a0, a1, a2, a3, a4);

var __ZN3mcl2fp10hexToArrayEPjmPKcm = Module["__ZN3mcl2fp10hexToArrayEPjmPKcm"] = (a0, a1, a2, a3) => (__ZN3mcl2fp10hexToArrayEPjmPKcm = Module["__ZN3mcl2fp10hexToArrayEPjmPKcm"] = wasmExports["_ZN3mcl2fp10hexToArrayEPjmPKcm"])(a0, a1, a2, a3);

var __ZN3mcl2fp10binToArrayEPjmPKcm = Module["__ZN3mcl2fp10binToArrayEPjmPKcm"] = (a0, a1, a2, a3) => (__ZN3mcl2fp10binToArrayEPjmPKcm = Module["__ZN3mcl2fp10binToArrayEPjmPKcm"] = wasmExports["_ZN3mcl2fp10binToArrayEPjmPKcm"])(a0, a1, a2, a3);

var __ZN3mcl2fp10arrayToDecEPcmPKjm = Module["__ZN3mcl2fp10arrayToDecEPcmPKjm"] = (a0, a1, a2, a3) => (__ZN3mcl2fp10arrayToDecEPcmPKjm = Module["__ZN3mcl2fp10arrayToDecEPcmPKjm"] = wasmExports["_ZN3mcl2fp10arrayToDecEPcmPKjm"])(a0, a1, a2, a3);

var __ZN3mcl2fp10decToArrayEPjmPKcm = Module["__ZN3mcl2fp10decToArrayEPjmPKcm"] = (a0, a1, a2, a3) => (__ZN3mcl2fp10decToArrayEPjmPKcm = Module["__ZN3mcl2fp10decToArrayEPjmPKcm"] = wasmExports["_ZN3mcl2fp10decToArrayEPjmPKcm"])(a0, a1, a2, a3);

var __ZN3mcl2fp10arrayToStrEPcmPKjmib = Module["__ZN3mcl2fp10arrayToStrEPcmPKjmib"] = (a0, a1, a2, a3, a4, a5) => (__ZN3mcl2fp10arrayToStrEPcmPKjmib = Module["__ZN3mcl2fp10arrayToStrEPcmPKjmib"] = wasmExports["_ZN3mcl2fp10arrayToStrEPcmPKjmib"])(a0, a1, a2, a3, a4, a5);

var __ZN3mcl2fp10strToArrayEPbPjmPKcmi = Module["__ZN3mcl2fp10strToArrayEPbPjmPKcmi"] = (a0, a1, a2, a3, a4, a5) => (__ZN3mcl2fp10strToArrayEPbPjmPKcmi = Module["__ZN3mcl2fp10strToArrayEPbPjmPKcmi"] = wasmExports["_ZN3mcl2fp10strToArrayEPbPjmPKcmi"])(a0, a1, a2, a3, a4, a5);

var __ZN3mcl3Fp24mulAEPjPKjS3_ = Module["__ZN3mcl3Fp24mulAEPjPKjS3_"] = (a0, a1, a2) => (__ZN3mcl3Fp24mulAEPjPKjS3_ = Module["__ZN3mcl3Fp24mulAEPjPKjS3_"] = wasmExports["_ZN3mcl3Fp24mulAEPjPKjS3_"])(a0, a1, a2);

var __ZN3mcl3Fp24initEPb = Module["__ZN3mcl3Fp24initEPb"] = a0 => (__ZN3mcl3Fp24initEPb = Module["__ZN3mcl3Fp24initEPb"] = wasmExports["_ZN3mcl3Fp24initEPb"])(a0);

var __ZN3mcl3Fp63sqrERS0_RKS0_ = Module["__ZN3mcl3Fp63sqrERS0_RKS0_"] = (a0, a1) => (__ZN3mcl3Fp63sqrERS0_RKS0_ = Module["__ZN3mcl3Fp63sqrERS0_RKS0_"] = wasmExports["_ZN3mcl3Fp63sqrERS0_RKS0_"])(a0, a1);

var __ZN3mcl3Fp63mulERS0_RKS0_S3_ = Module["__ZN3mcl3Fp63mulERS0_RKS0_S3_"] = (a0, a1, a2) => (__ZN3mcl3Fp63mulERS0_RKS0_S3_ = Module["__ZN3mcl3Fp63mulERS0_RKS0_S3_"] = wasmExports["_ZN3mcl3Fp63mulERS0_RKS0_S3_"])(a0, a1, a2);

var __ZN3mcl3Fp63invERS0_RKS0_ = Module["__ZN3mcl3Fp63invERS0_RKS0_"] = (a0, a1) => (__ZN3mcl3Fp63invERS0_RKS0_ = Module["__ZN3mcl3Fp63invERS0_RKS0_"] = wasmExports["_ZN3mcl3Fp63invERS0_RKS0_"])(a0, a1);

var __ZN3mcl2fp11isEnableJITEv = Module["__ZN3mcl2fp11isEnableJITEv"] = () => (__ZN3mcl2fp11isEnableJITEv = Module["__ZN3mcl2fp11isEnableJITEv"] = wasmExports["_ZN3mcl2fp11isEnableJITEv"])();

var __ZN3mcl2fp6sha256EPvjPKvj = Module["__ZN3mcl2fp6sha256EPvjPKvj"] = (a0, a1, a2, a3) => (__ZN3mcl2fp6sha256EPvjPKvj = Module["__ZN3mcl2fp6sha256EPvjPKvj"] = wasmExports["_ZN3mcl2fp6sha256EPvjPKvj"])(a0, a1, a2, a3);

var __ZN3mcl2fp6sha512EPvjPKvj = Module["__ZN3mcl2fp6sha512EPvjPKvj"] = (a0, a1, a2, a3) => (__ZN3mcl2fp6sha512EPvjPKvj = Module["__ZN3mcl2fp6sha512EPvjPKvj"] = wasmExports["_ZN3mcl2fp6sha512EPvjPKvj"])(a0, a1, a2, a3);

var __ZN3mcl2fp18expand_message_xmdEPhmPKvmS3_m = Module["__ZN3mcl2fp18expand_message_xmdEPhmPKvmS3_m"] = (a0, a1, a2, a3, a4, a5) => (__ZN3mcl2fp18expand_message_xmdEPhmPKvmS3_m = Module["__ZN3mcl2fp18expand_message_xmdEPhmPKvmS3_m"] = wasmExports["_ZN3mcl2fp18expand_message_xmdEPhmPKvmS3_m"])(a0, a1, a2, a3, a4, a5);

var __ZN3mcl2fp2Op4initERKNS_4VintEiiim = Module["__ZN3mcl2fp2Op4initERKNS_4VintEiiim"] = (a0, a1, a2, a3, a4, a5) => (__ZN3mcl2fp2Op4initERKNS_4VintEiiim = Module["__ZN3mcl2fp2Op4initERKNS_4VintEiiim"] = wasmExports["_ZN3mcl2fp2Op4initERKNS_4VintEiiim"])(a0, a1, a2, a3, a4, a5);

var __ZN3mcl2fp9getUint64EPbRKNS0_5BlockE = Module["__ZN3mcl2fp9getUint64EPbRKNS0_5BlockE"] = (a0, a1) => (__ZN3mcl2fp9getUint64EPbRKNS0_5BlockE = Module["__ZN3mcl2fp9getUint64EPbRKNS0_5BlockE"] = wasmExports["_ZN3mcl2fp9getUint64EPbRKNS0_5BlockE"])(a0, a1);

var __ZN3mcl2fp8getInt64EPbRNS0_5BlockERKNS0_2OpE = Module["__ZN3mcl2fp8getInt64EPbRNS0_5BlockERKNS0_2OpE"] = (a0, a1, a2) => (__ZN3mcl2fp8getInt64EPbRNS0_5BlockERKNS0_2OpE = Module["__ZN3mcl2fp8getInt64EPbRNS0_5BlockERKNS0_2OpE"] = wasmExports["_ZN3mcl2fp8getInt64EPbRNS0_5BlockERKNS0_2OpE"])(a0, a1, a2);

var __ZN3mcl12setMapToModeEi = Module["__ZN3mcl12setMapToModeEi"] = a0 => (__ZN3mcl12setMapToModeEi = Module["__ZN3mcl12setMapToModeEi"] = wasmExports["_ZN3mcl12setMapToModeEi"])(a0);

var __ZN3mcl12getMapToModeEv = Module["__ZN3mcl12getMapToModeEv"] = () => (__ZN3mcl12getMapToModeEv = Module["__ZN3mcl12getMapToModeEv"] = wasmExports["_ZN3mcl12getMapToModeEv"])();

var __ZN3mcl7mapToG1EPbRNS_3EcTINS_3FpTILi0ELm384EEEEERKS3_ = Module["__ZN3mcl7mapToG1EPbRNS_3EcTINS_3FpTILi0ELm384EEEEERKS3_"] = (a0, a1, a2) => (__ZN3mcl7mapToG1EPbRNS_3EcTINS_3FpTILi0ELm384EEEEERKS3_ = Module["__ZN3mcl7mapToG1EPbRNS_3EcTINS_3FpTILi0ELm384EEEEERKS3_"] = wasmExports["_ZN3mcl7mapToG1EPbRNS_3EcTINS_3FpTILi0ELm384EEEEERKS3_"])(a0, a1, a2);

var __ZN3mcl7mapToG2EPbRNS_3EcTINS_3Fp2EEERKS2_ = Module["__ZN3mcl7mapToG2EPbRNS_3EcTINS_3Fp2EEERKS2_"] = (a0, a1, a2) => (__ZN3mcl7mapToG2EPbRNS_3EcTINS_3Fp2EEERKS2_ = Module["__ZN3mcl7mapToG2EPbRNS_3EcTINS_3Fp2EEERKS2_"] = wasmExports["_ZN3mcl7mapToG2EPbRNS_3EcTINS_3Fp2EEERKS2_"])(a0, a1, a2);

var __ZN3mcl14hashAndMapToG1ERNS_3EcTINS_3FpTILi0ELm384EEEEEPKvm = Module["__ZN3mcl14hashAndMapToG1ERNS_3EcTINS_3FpTILi0ELm384EEEEEPKvm"] = (a0, a1, a2) => (__ZN3mcl14hashAndMapToG1ERNS_3EcTINS_3FpTILi0ELm384EEEEEPKvm = Module["__ZN3mcl14hashAndMapToG1ERNS_3EcTINS_3FpTILi0ELm384EEEEEPKvm"] = wasmExports["_ZN3mcl14hashAndMapToG1ERNS_3EcTINS_3FpTILi0ELm384EEEEEPKvm"])(a0, a1, a2);

var __ZN3mcl14hashAndMapToG2ERNS_3EcTINS_3Fp2EEEPKvm = Module["__ZN3mcl14hashAndMapToG2ERNS_3EcTINS_3Fp2EEEPKvm"] = (a0, a1, a2) => (__ZN3mcl14hashAndMapToG2ERNS_3EcTINS_3Fp2EEEPKvm = Module["__ZN3mcl14hashAndMapToG2ERNS_3EcTINS_3Fp2EEEPKvm"] = wasmExports["_ZN3mcl14hashAndMapToG2ERNS_3EcTINS_3Fp2EEEPKvm"])(a0, a1, a2);

var __ZN3mcl14hashAndMapToG1ERNS_3EcTINS_3FpTILi0ELm384EEEEEPKvmPKcm = Module["__ZN3mcl14hashAndMapToG1ERNS_3EcTINS_3FpTILi0ELm384EEEEEPKvmPKcm"] = (a0, a1, a2, a3, a4) => (__ZN3mcl14hashAndMapToG1ERNS_3EcTINS_3FpTILi0ELm384EEEEEPKvmPKcm = Module["__ZN3mcl14hashAndMapToG1ERNS_3EcTINS_3FpTILi0ELm384EEEEEPKvmPKcm"] = wasmExports["_ZN3mcl14hashAndMapToG1ERNS_3EcTINS_3FpTILi0ELm384EEEEEPKvmPKcm"])(a0, a1, a2, a3, a4);

var __ZN3mcl14hashAndMapToG2ERNS_3EcTINS_3Fp2EEEPKvmPKcm = Module["__ZN3mcl14hashAndMapToG2ERNS_3EcTINS_3Fp2EEEPKvmPKcm"] = (a0, a1, a2, a3, a4) => (__ZN3mcl14hashAndMapToG2ERNS_3EcTINS_3Fp2EEEPKvmPKcm = Module["__ZN3mcl14hashAndMapToG2ERNS_3EcTINS_3Fp2EEEPKvmPKcm"] = wasmExports["_ZN3mcl14hashAndMapToG2ERNS_3EcTINS_3Fp2EEEPKvmPKcm"])(a0, a1, a2, a3, a4);

var __ZN3mcl8setDstG1EPKcm = Module["__ZN3mcl8setDstG1EPKcm"] = (a0, a1) => (__ZN3mcl8setDstG1EPKcm = Module["__ZN3mcl8setDstG1EPKcm"] = wasmExports["_ZN3mcl8setDstG1EPKcm"])(a0, a1);

var __ZN3mcl8setDstG2EPKcm = Module["__ZN3mcl8setDstG2EPKcm"] = (a0, a1) => (__ZN3mcl8setDstG2EPKcm = Module["__ZN3mcl8setDstG2EPKcm"] = wasmExports["_ZN3mcl8setDstG2EPKcm"])(a0, a1);

var __ZN3mcl17isValidOrderBLS12ERKNS_3EcTINS_3FpTILi0ELm384EEEEE = Module["__ZN3mcl17isValidOrderBLS12ERKNS_3EcTINS_3FpTILi0ELm384EEEEE"] = a0 => (__ZN3mcl17isValidOrderBLS12ERKNS_3EcTINS_3FpTILi0ELm384EEEEE = Module["__ZN3mcl17isValidOrderBLS12ERKNS_3EcTINS_3FpTILi0ELm384EEEEE"] = wasmExports["_ZN3mcl17isValidOrderBLS12ERKNS_3EcTINS_3FpTILi0ELm384EEEEE"])(a0);

var __ZN3mcl9FrobeniusERNS_3EcTINS_3Fp2EEERKS2_ = Module["__ZN3mcl9FrobeniusERNS_3EcTINS_3Fp2EEERKS2_"] = (a0, a1) => (__ZN3mcl9FrobeniusERNS_3EcTINS_3Fp2EEERKS2_ = Module["__ZN3mcl9FrobeniusERNS_3EcTINS_3Fp2EEERKS2_"] = wasmExports["_ZN3mcl9FrobeniusERNS_3EcTINS_3Fp2EEERKS2_"])(a0, a1);

var __ZN3mcl13getCurveParamEv = Module["__ZN3mcl13getCurveParamEv"] = () => (__ZN3mcl13getCurveParamEv = Module["__ZN3mcl13getCurveParamEv"] = wasmExports["_ZN3mcl13getCurveParamEv"])();

var __ZN3mcl12getCurveTypeEv = Module["__ZN3mcl12getCurveTypeEv"] = () => (__ZN3mcl12getCurveTypeEv = Module["__ZN3mcl12getCurveTypeEv"] = wasmExports["_ZN3mcl12getCurveTypeEv"])();

var __ZN3mcl8finalExpERNS_4Fp12ERKS0_ = Module["__ZN3mcl8finalExpERNS_4Fp12ERKS0_"] = (a0, a1) => (__ZN3mcl8finalExpERNS_4Fp12ERKS0_ = Module["__ZN3mcl8finalExpERNS_4Fp12ERKS0_"] = wasmExports["_ZN3mcl8finalExpERNS_4Fp12ERKS0_"])(a0, a1);

var __ZN3mcl10millerLoopERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEERKNS2_INS_3Fp2EEE = Module["__ZN3mcl10millerLoopERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEERKNS2_INS_3Fp2EEE"] = (a0, a1, a2) => (__ZN3mcl10millerLoopERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEERKNS2_INS_3Fp2EEE = Module["__ZN3mcl10millerLoopERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEERKNS2_INS_3Fp2EEE"] = wasmExports["_ZN3mcl10millerLoopERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEERKNS2_INS_3Fp2EEE"])(a0, a1, a2);

var __ZN3mcl7pairingERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEERKNS2_INS_3Fp2EEE = Module["__ZN3mcl7pairingERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEERKNS2_INS_3Fp2EEE"] = (a0, a1, a2) => (__ZN3mcl7pairingERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEERKNS2_INS_3Fp2EEE = Module["__ZN3mcl7pairingERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEERKNS2_INS_3Fp2EEE"] = wasmExports["_ZN3mcl7pairingERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEERKNS2_INS_3Fp2EEE"])(a0, a1, a2);

var __ZN3mcl24getPrecomputedQcoeffSizeEv = Module["__ZN3mcl24getPrecomputedQcoeffSizeEv"] = () => (__ZN3mcl24getPrecomputedQcoeffSizeEv = Module["__ZN3mcl24getPrecomputedQcoeffSizeEv"] = wasmExports["_ZN3mcl24getPrecomputedQcoeffSizeEv"])();

var __ZN3mcl12precomputeG2EPNS_3Fp6ERKNS_3EcTINS_3Fp2EEE = Module["__ZN3mcl12precomputeG2EPNS_3Fp6ERKNS_3EcTINS_3Fp2EEE"] = (a0, a1) => (__ZN3mcl12precomputeG2EPNS_3Fp6ERKNS_3EcTINS_3Fp2EEE = Module["__ZN3mcl12precomputeG2EPNS_3Fp6ERKNS_3EcTINS_3Fp2EEE"] = wasmExports["_ZN3mcl12precomputeG2EPNS_3Fp6ERKNS_3EcTINS_3Fp2EEE"])(a0, a1);

var __ZN3mcl21precomputedMillerLoopERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEEPKNS_3Fp6E = Module["__ZN3mcl21precomputedMillerLoopERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEEPKNS_3Fp6E"] = (a0, a1, a2) => (__ZN3mcl21precomputedMillerLoopERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEEPKNS_3Fp6E = Module["__ZN3mcl21precomputedMillerLoopERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEEPKNS_3Fp6E"] = wasmExports["_ZN3mcl21precomputedMillerLoopERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEEPKNS_3Fp6E"])(a0, a1, a2);

var __ZN3mcl27precomputedMillerLoop2mixedERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEERKNS2_INS_3Fp2EEES7_PKNS_3Fp6E = Module["__ZN3mcl27precomputedMillerLoop2mixedERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEERKNS2_INS_3Fp2EEES7_PKNS_3Fp6E"] = (a0, a1, a2, a3, a4) => (__ZN3mcl27precomputedMillerLoop2mixedERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEERKNS2_INS_3Fp2EEES7_PKNS_3Fp6E = Module["__ZN3mcl27precomputedMillerLoop2mixedERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEERKNS2_INS_3Fp2EEES7_PKNS_3Fp6E"] = wasmExports["_ZN3mcl27precomputedMillerLoop2mixedERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEERKNS2_INS_3Fp2EEES7_PKNS_3Fp6E"])(a0, a1, a2, a3, a4);

var __ZN3mcl22precomputedMillerLoop2ERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEEPKNS_3Fp6ES7_SA_ = Module["__ZN3mcl22precomputedMillerLoop2ERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEEPKNS_3Fp6ES7_SA_"] = (a0, a1, a2, a3, a4) => (__ZN3mcl22precomputedMillerLoop2ERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEEPKNS_3Fp6ES7_SA_ = Module["__ZN3mcl22precomputedMillerLoop2ERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEEPKNS_3Fp6ES7_SA_"] = wasmExports["_ZN3mcl22precomputedMillerLoop2ERNS_4Fp12ERKNS_3EcTINS_3FpTILi0ELm384EEEEEPKNS_3Fp6ES7_SA_"])(a0, a1, a2, a3, a4);

var __ZN3mcl13millerLoopVecERNS_4Fp12EPKNS_3EcTINS_3FpTILi0ELm384EEEEEPKNS2_INS_3Fp2EEEmb = Module["__ZN3mcl13millerLoopVecERNS_4Fp12EPKNS_3EcTINS_3FpTILi0ELm384EEEEEPKNS2_INS_3Fp2EEEmb"] = (a0, a1, a2, a3, a4) => (__ZN3mcl13millerLoopVecERNS_4Fp12EPKNS_3EcTINS_3FpTILi0ELm384EEEEEPKNS2_INS_3Fp2EEEmb = Module["__ZN3mcl13millerLoopVecERNS_4Fp12EPKNS_3EcTINS_3FpTILi0ELm384EEEEEPKNS2_INS_3Fp2EEEmb"] = wasmExports["_ZN3mcl13millerLoopVecERNS_4Fp12EPKNS_3EcTINS_3FpTILi0ELm384EEEEEPKNS2_INS_3Fp2EEEmb"])(a0, a1, a2, a3, a4);

var __ZN3mcl15millerLoopVecMTERNS_4Fp12EPKNS_3EcTINS_3FpTILi0ELm384EEEEEPKNS2_INS_3Fp2EEEmm = Module["__ZN3mcl15millerLoopVecMTERNS_4Fp12EPKNS_3EcTINS_3FpTILi0ELm384EEEEEPKNS2_INS_3Fp2EEEmm"] = (a0, a1, a2, a3, a4) => (__ZN3mcl15millerLoopVecMTERNS_4Fp12EPKNS_3EcTINS_3FpTILi0ELm384EEEEEPKNS2_INS_3Fp2EEEmm = Module["__ZN3mcl15millerLoopVecMTERNS_4Fp12EPKNS_3EcTINS_3FpTILi0ELm384EEEEEPKNS2_INS_3Fp2EEEmm"] = wasmExports["_ZN3mcl15millerLoopVecMTERNS_4Fp12EPKNS_3EcTINS_3FpTILi0ELm384EEEEEPKNS2_INS_3Fp2EEEmm"])(a0, a1, a2, a3, a4);

var __ZN3mcl13verifyOrderG1Eb = Module["__ZN3mcl13verifyOrderG1Eb"] = a0 => (__ZN3mcl13verifyOrderG1Eb = Module["__ZN3mcl13verifyOrderG1Eb"] = wasmExports["_ZN3mcl13verifyOrderG1Eb"])(a0);

var __ZN3mcl13verifyOrderG2Eb = Module["__ZN3mcl13verifyOrderG2Eb"] = a0 => (__ZN3mcl13verifyOrderG2Eb = Module["__ZN3mcl13verifyOrderG2Eb"] = wasmExports["_ZN3mcl13verifyOrderG2Eb"])(a0);

var __ZN3mcl17isValidOrderBLS12ERKNS_3EcTINS_3Fp2EEE = Module["__ZN3mcl17isValidOrderBLS12ERKNS_3EcTINS_3Fp2EEE"] = a0 => (__ZN3mcl17isValidOrderBLS12ERKNS_3EcTINS_3Fp2EEE = Module["__ZN3mcl17isValidOrderBLS12ERKNS_3EcTINS_3Fp2EEE"] = wasmExports["_ZN3mcl17isValidOrderBLS12ERKNS_3EcTINS_3Fp2EEE"])(a0);

var __ZN3mcl10Frobenius2ERNS_3EcTINS_3Fp2EEERKS2_ = Module["__ZN3mcl10Frobenius2ERNS_3EcTINS_3Fp2EEERKS2_"] = (a0, a1) => (__ZN3mcl10Frobenius2ERNS_3EcTINS_3Fp2EEERKS2_ = Module["__ZN3mcl10Frobenius2ERNS_3EcTINS_3Fp2EEERKS2_"] = wasmExports["_ZN3mcl10Frobenius2ERNS_3EcTINS_3Fp2EEERKS2_"])(a0, a1);

var __ZN3mcl10Frobenius3ERNS_3EcTINS_3Fp2EEERKS2_ = Module["__ZN3mcl10Frobenius3ERNS_3EcTINS_3Fp2EEERKS2_"] = (a0, a1) => (__ZN3mcl10Frobenius3ERNS_3EcTINS_3Fp2EEERKS2_ = Module["__ZN3mcl10Frobenius3ERNS_3EcTINS_3Fp2EEERKS2_"] = wasmExports["_ZN3mcl10Frobenius3ERNS_3EcTINS_3Fp2EEERKS2_"])(a0, a1);

var __ZN3mcl4initEPbRKNS_10CurveParamE = Module["__ZN3mcl4initEPbRKNS_10CurveParamE"] = (a0, a1) => (__ZN3mcl4initEPbRKNS_10CurveParamE = Module["__ZN3mcl4initEPbRKNS_10CurveParamE"] = wasmExports["_ZN3mcl4initEPbRKNS_10CurveParamE"])(a0, a1);

var __ZN3mcl11initPairingEPbRKNS_10CurveParamE = Module["__ZN3mcl11initPairingEPbRKNS_10CurveParamE"] = (a0, a1) => (__ZN3mcl11initPairingEPbRKNS_10CurveParamE = Module["__ZN3mcl11initPairingEPbRKNS_10CurveParamE"] = wasmExports["_ZN3mcl11initPairingEPbRKNS_10CurveParamE"])(a0, a1);

var __ZN3mcl10initG1onlyEPbRKNS_7EcParamE = Module["__ZN3mcl10initG1onlyEPbRKNS_7EcParamE"] = (a0, a1) => (__ZN3mcl10initG1onlyEPbRKNS_7EcParamE = Module["__ZN3mcl10initG1onlyEPbRKNS_7EcParamE"] = wasmExports["_ZN3mcl10initG1onlyEPbRKNS_7EcParamE"])(a0, a1);

var __ZN3mcl14getG1basePointEv = Module["__ZN3mcl14getG1basePointEv"] = () => (__ZN3mcl14getG1basePointEv = Module["__ZN3mcl14getG1basePointEv"] = wasmExports["_ZN3mcl14getG1basePointEv"])();

var __ZN3mcl9isValidGTERKNS_4Fp12E = Module["__ZN3mcl9isValidGTERKNS_4Fp12E"] = a0 => (__ZN3mcl9isValidGTERKNS_4Fp12E = Module["__ZN3mcl9isValidGTERKNS_4Fp12E"] = wasmExports["_ZN3mcl9isValidGTERKNS_4Fp12E"])(a0);

var _mclBnMalloc = Module["_mclBnMalloc"] = a0 => (_mclBnMalloc = Module["_mclBnMalloc"] = wasmExports["mclBnMalloc"])(a0);

var _mclBnFree = Module["_mclBnFree"] = a0 => (_mclBnFree = Module["_mclBnFree"] = wasmExports["mclBnFree"])(a0);

var _mclBn_getVersion = Module["_mclBn_getVersion"] = () => (_mclBn_getVersion = Module["_mclBn_getVersion"] = wasmExports["mclBn_getVersion"])();

var _mclBn_init = Module["_mclBn_init"] = (a0, a1) => (_mclBn_init = Module["_mclBn_init"] = wasmExports["mclBn_init"])(a0, a1);

var _mclBn_getCurveType = Module["_mclBn_getCurveType"] = () => (_mclBn_getCurveType = Module["_mclBn_getCurveType"] = wasmExports["mclBn_getCurveType"])();

var _mclBn_getOpUnitSize = Module["_mclBn_getOpUnitSize"] = () => (_mclBn_getOpUnitSize = Module["_mclBn_getOpUnitSize"] = wasmExports["mclBn_getOpUnitSize"])();

var _mclBn_getG1ByteSize = Module["_mclBn_getG1ByteSize"] = () => (_mclBn_getG1ByteSize = Module["_mclBn_getG1ByteSize"] = wasmExports["mclBn_getG1ByteSize"])();

var _mclBn_getG2ByteSize = Module["_mclBn_getG2ByteSize"] = () => (_mclBn_getG2ByteSize = Module["_mclBn_getG2ByteSize"] = wasmExports["mclBn_getG2ByteSize"])();

var _mclBn_getFrByteSize = Module["_mclBn_getFrByteSize"] = () => (_mclBn_getFrByteSize = Module["_mclBn_getFrByteSize"] = wasmExports["mclBn_getFrByteSize"])();

var _mclBn_getFpByteSize = Module["_mclBn_getFpByteSize"] = () => (_mclBn_getFpByteSize = Module["_mclBn_getFpByteSize"] = wasmExports["mclBn_getFpByteSize"])();

var _mclBn_getCurveOrder = Module["_mclBn_getCurveOrder"] = (a0, a1) => (_mclBn_getCurveOrder = Module["_mclBn_getCurveOrder"] = wasmExports["mclBn_getCurveOrder"])(a0, a1);

var _mclBn_getFieldOrder = Module["_mclBn_getFieldOrder"] = (a0, a1) => (_mclBn_getFieldOrder = Module["_mclBn_getFieldOrder"] = wasmExports["mclBn_getFieldOrder"])(a0, a1);

var _mclBn_setETHserialization = Module["_mclBn_setETHserialization"] = a0 => (_mclBn_setETHserialization = Module["_mclBn_setETHserialization"] = wasmExports["mclBn_setETHserialization"])(a0);

var _mclBn_getETHserialization = Module["_mclBn_getETHserialization"] = () => (_mclBn_getETHserialization = Module["_mclBn_getETHserialization"] = wasmExports["mclBn_getETHserialization"])();

var _mclBn_setMapToMode = Module["_mclBn_setMapToMode"] = a0 => (_mclBn_setMapToMode = Module["_mclBn_setMapToMode"] = wasmExports["mclBn_setMapToMode"])(a0);

var _mclBnG1_setDst = Module["_mclBnG1_setDst"] = (a0, a1) => (_mclBnG1_setDst = Module["_mclBnG1_setDst"] = wasmExports["mclBnG1_setDst"])(a0, a1);

var _mclBnG2_setDst = Module["_mclBnG2_setDst"] = (a0, a1) => (_mclBnG2_setDst = Module["_mclBnG2_setDst"] = wasmExports["mclBnG2_setDst"])(a0, a1);

var _mclBnFr_clear = Module["_mclBnFr_clear"] = a0 => (_mclBnFr_clear = Module["_mclBnFr_clear"] = wasmExports["mclBnFr_clear"])(a0);

var _mclBnFr_setInt = Module["_mclBnFr_setInt"] = (a0, a1) => (_mclBnFr_setInt = Module["_mclBnFr_setInt"] = wasmExports["mclBnFr_setInt"])(a0, a1);

var _mclBnFr_setInt32 = Module["_mclBnFr_setInt32"] = (a0, a1) => (_mclBnFr_setInt32 = Module["_mclBnFr_setInt32"] = wasmExports["mclBnFr_setInt32"])(a0, a1);

var _mclBnFr_setStr = Module["_mclBnFr_setStr"] = (a0, a1, a2, a3) => (_mclBnFr_setStr = Module["_mclBnFr_setStr"] = wasmExports["mclBnFr_setStr"])(a0, a1, a2, a3);

var _mclBnFr_setLittleEndian = Module["_mclBnFr_setLittleEndian"] = (a0, a1, a2) => (_mclBnFr_setLittleEndian = Module["_mclBnFr_setLittleEndian"] = wasmExports["mclBnFr_setLittleEndian"])(a0, a1, a2);

var _mclBnFr_setBigEndianMod = Module["_mclBnFr_setBigEndianMod"] = (a0, a1, a2) => (_mclBnFr_setBigEndianMod = Module["_mclBnFr_setBigEndianMod"] = wasmExports["mclBnFr_setBigEndianMod"])(a0, a1, a2);

var _mclBnFr_getLittleEndian = Module["_mclBnFr_getLittleEndian"] = (a0, a1, a2) => (_mclBnFr_getLittleEndian = Module["_mclBnFr_getLittleEndian"] = wasmExports["mclBnFr_getLittleEndian"])(a0, a1, a2);

var _mclBnFr_setLittleEndianMod = Module["_mclBnFr_setLittleEndianMod"] = (a0, a1, a2) => (_mclBnFr_setLittleEndianMod = Module["_mclBnFr_setLittleEndianMod"] = wasmExports["mclBnFr_setLittleEndianMod"])(a0, a1, a2);

var _mclBnFr_deserialize = Module["_mclBnFr_deserialize"] = (a0, a1, a2) => (_mclBnFr_deserialize = Module["_mclBnFr_deserialize"] = wasmExports["mclBnFr_deserialize"])(a0, a1, a2);

var _mclBnFr_isValid = Module["_mclBnFr_isValid"] = a0 => (_mclBnFr_isValid = Module["_mclBnFr_isValid"] = wasmExports["mclBnFr_isValid"])(a0);

var _mclBnFr_isEqual = Module["_mclBnFr_isEqual"] = (a0, a1) => (_mclBnFr_isEqual = Module["_mclBnFr_isEqual"] = wasmExports["mclBnFr_isEqual"])(a0, a1);

var _mclBnFr_isZero = Module["_mclBnFr_isZero"] = a0 => (_mclBnFr_isZero = Module["_mclBnFr_isZero"] = wasmExports["mclBnFr_isZero"])(a0);

var _mclBnFr_isOne = Module["_mclBnFr_isOne"] = a0 => (_mclBnFr_isOne = Module["_mclBnFr_isOne"] = wasmExports["mclBnFr_isOne"])(a0);

var _mclBnFr_isOdd = Module["_mclBnFr_isOdd"] = a0 => (_mclBnFr_isOdd = Module["_mclBnFr_isOdd"] = wasmExports["mclBnFr_isOdd"])(a0);

var _mclBnFr_isNegative = Module["_mclBnFr_isNegative"] = a0 => (_mclBnFr_isNegative = Module["_mclBnFr_isNegative"] = wasmExports["mclBnFr_isNegative"])(a0);

var _mclBnFr_cmp = Module["_mclBnFr_cmp"] = (a0, a1) => (_mclBnFr_cmp = Module["_mclBnFr_cmp"] = wasmExports["mclBnFr_cmp"])(a0, a1);

var _mclBnFr_setByCSPRNG = Module["_mclBnFr_setByCSPRNG"] = a0 => (_mclBnFr_setByCSPRNG = Module["_mclBnFr_setByCSPRNG"] = wasmExports["mclBnFr_setByCSPRNG"])(a0);

var _mclBnFp_setByCSPRNG = Module["_mclBnFp_setByCSPRNG"] = a0 => (_mclBnFp_setByCSPRNG = Module["_mclBnFp_setByCSPRNG"] = wasmExports["mclBnFp_setByCSPRNG"])(a0);

var _mclBn_setRandFunc = Module["_mclBn_setRandFunc"] = (a0, a1) => (_mclBn_setRandFunc = Module["_mclBn_setRandFunc"] = wasmExports["mclBn_setRandFunc"])(a0, a1);

var _mclBnFr_setHashOf = Module["_mclBnFr_setHashOf"] = (a0, a1, a2) => (_mclBnFr_setHashOf = Module["_mclBnFr_setHashOf"] = wasmExports["mclBnFr_setHashOf"])(a0, a1, a2);

var _mclBnFr_getStr = Module["_mclBnFr_getStr"] = (a0, a1, a2, a3) => (_mclBnFr_getStr = Module["_mclBnFr_getStr"] = wasmExports["mclBnFr_getStr"])(a0, a1, a2, a3);

var _mclBnFr_serialize = Module["_mclBnFr_serialize"] = (a0, a1, a2) => (_mclBnFr_serialize = Module["_mclBnFr_serialize"] = wasmExports["mclBnFr_serialize"])(a0, a1, a2);

var _mclBnFr_neg = Module["_mclBnFr_neg"] = (a0, a1) => (_mclBnFr_neg = Module["_mclBnFr_neg"] = wasmExports["mclBnFr_neg"])(a0, a1);

var _mclBnFr_inv = Module["_mclBnFr_inv"] = (a0, a1) => (_mclBnFr_inv = Module["_mclBnFr_inv"] = wasmExports["mclBnFr_inv"])(a0, a1);

var _mclBnFr_sqr = Module["_mclBnFr_sqr"] = (a0, a1) => (_mclBnFr_sqr = Module["_mclBnFr_sqr"] = wasmExports["mclBnFr_sqr"])(a0, a1);

var _mclBnFr_add = Module["_mclBnFr_add"] = (a0, a1, a2) => (_mclBnFr_add = Module["_mclBnFr_add"] = wasmExports["mclBnFr_add"])(a0, a1, a2);

var _mclBnFr_sub = Module["_mclBnFr_sub"] = (a0, a1, a2) => (_mclBnFr_sub = Module["_mclBnFr_sub"] = wasmExports["mclBnFr_sub"])(a0, a1, a2);

var _mclBnFr_mul = Module["_mclBnFr_mul"] = (a0, a1, a2) => (_mclBnFr_mul = Module["_mclBnFr_mul"] = wasmExports["mclBnFr_mul"])(a0, a1, a2);

var _mclBnFr_div = Module["_mclBnFr_div"] = (a0, a1, a2) => (_mclBnFr_div = Module["_mclBnFr_div"] = wasmExports["mclBnFr_div"])(a0, a1, a2);

var _mclBnFp_neg = Module["_mclBnFp_neg"] = (a0, a1) => (_mclBnFp_neg = Module["_mclBnFp_neg"] = wasmExports["mclBnFp_neg"])(a0, a1);

var _mclBnFp_inv = Module["_mclBnFp_inv"] = (a0, a1) => (_mclBnFp_inv = Module["_mclBnFp_inv"] = wasmExports["mclBnFp_inv"])(a0, a1);

var _mclBnFp_sqr = Module["_mclBnFp_sqr"] = (a0, a1) => (_mclBnFp_sqr = Module["_mclBnFp_sqr"] = wasmExports["mclBnFp_sqr"])(a0, a1);

var _mclBnFp_add = Module["_mclBnFp_add"] = (a0, a1, a2) => (_mclBnFp_add = Module["_mclBnFp_add"] = wasmExports["mclBnFp_add"])(a0, a1, a2);

var _mclBnFp_sub = Module["_mclBnFp_sub"] = (a0, a1, a2) => (_mclBnFp_sub = Module["_mclBnFp_sub"] = wasmExports["mclBnFp_sub"])(a0, a1, a2);

var _mclBnFp_mul = Module["_mclBnFp_mul"] = (a0, a1, a2) => (_mclBnFp_mul = Module["_mclBnFp_mul"] = wasmExports["mclBnFp_mul"])(a0, a1, a2);

var _mclBnFp_div = Module["_mclBnFp_div"] = (a0, a1, a2) => (_mclBnFp_div = Module["_mclBnFp_div"] = wasmExports["mclBnFp_div"])(a0, a1, a2);

var _mclBnFp2_neg = Module["_mclBnFp2_neg"] = (a0, a1) => (_mclBnFp2_neg = Module["_mclBnFp2_neg"] = wasmExports["mclBnFp2_neg"])(a0, a1);

var _mclBnFp2_inv = Module["_mclBnFp2_inv"] = (a0, a1) => (_mclBnFp2_inv = Module["_mclBnFp2_inv"] = wasmExports["mclBnFp2_inv"])(a0, a1);

var _mclBnFp2_sqr = Module["_mclBnFp2_sqr"] = (a0, a1) => (_mclBnFp2_sqr = Module["_mclBnFp2_sqr"] = wasmExports["mclBnFp2_sqr"])(a0, a1);

var _mclBnFp2_add = Module["_mclBnFp2_add"] = (a0, a1, a2) => (_mclBnFp2_add = Module["_mclBnFp2_add"] = wasmExports["mclBnFp2_add"])(a0, a1, a2);

var _mclBnFp2_sub = Module["_mclBnFp2_sub"] = (a0, a1, a2) => (_mclBnFp2_sub = Module["_mclBnFp2_sub"] = wasmExports["mclBnFp2_sub"])(a0, a1, a2);

var _mclBnFp2_mul = Module["_mclBnFp2_mul"] = (a0, a1, a2) => (_mclBnFp2_mul = Module["_mclBnFp2_mul"] = wasmExports["mclBnFp2_mul"])(a0, a1, a2);

var _mclBnFp2_div = Module["_mclBnFp2_div"] = (a0, a1, a2) => (_mclBnFp2_div = Module["_mclBnFp2_div"] = wasmExports["mclBnFp2_div"])(a0, a1, a2);

var _mclBnFr_squareRoot = Module["_mclBnFr_squareRoot"] = (a0, a1) => (_mclBnFr_squareRoot = Module["_mclBnFr_squareRoot"] = wasmExports["mclBnFr_squareRoot"])(a0, a1);

var _mclBnFp_squareRoot = Module["_mclBnFp_squareRoot"] = (a0, a1) => (_mclBnFp_squareRoot = Module["_mclBnFp_squareRoot"] = wasmExports["mclBnFp_squareRoot"])(a0, a1);

var _mclBnFp2_squareRoot = Module["_mclBnFp2_squareRoot"] = (a0, a1) => (_mclBnFp2_squareRoot = Module["_mclBnFp2_squareRoot"] = wasmExports["mclBnFp2_squareRoot"])(a0, a1);

var _mclBnG1_clear = Module["_mclBnG1_clear"] = a0 => (_mclBnG1_clear = Module["_mclBnG1_clear"] = wasmExports["mclBnG1_clear"])(a0);

var _mclBnG1_setStr = Module["_mclBnG1_setStr"] = (a0, a1, a2, a3) => (_mclBnG1_setStr = Module["_mclBnG1_setStr"] = wasmExports["mclBnG1_setStr"])(a0, a1, a2, a3);

var _mclBnG1_deserialize = Module["_mclBnG1_deserialize"] = (a0, a1, a2) => (_mclBnG1_deserialize = Module["_mclBnG1_deserialize"] = wasmExports["mclBnG1_deserialize"])(a0, a1, a2);

var _mclBnG1_isValid = Module["_mclBnG1_isValid"] = a0 => (_mclBnG1_isValid = Module["_mclBnG1_isValid"] = wasmExports["mclBnG1_isValid"])(a0);

var _mclBnG1_isEqual = Module["_mclBnG1_isEqual"] = (a0, a1) => (_mclBnG1_isEqual = Module["_mclBnG1_isEqual"] = wasmExports["mclBnG1_isEqual"])(a0, a1);

var _mclBnG1_isZero = Module["_mclBnG1_isZero"] = a0 => (_mclBnG1_isZero = Module["_mclBnG1_isZero"] = wasmExports["mclBnG1_isZero"])(a0);

var _mclBnG1_isValidOrder = Module["_mclBnG1_isValidOrder"] = a0 => (_mclBnG1_isValidOrder = Module["_mclBnG1_isValidOrder"] = wasmExports["mclBnG1_isValidOrder"])(a0);

var _mclBnG1_hashAndMapTo = Module["_mclBnG1_hashAndMapTo"] = (a0, a1, a2) => (_mclBnG1_hashAndMapTo = Module["_mclBnG1_hashAndMapTo"] = wasmExports["mclBnG1_hashAndMapTo"])(a0, a1, a2);

var _mclBnG1_hashAndMapToWithDst = Module["_mclBnG1_hashAndMapToWithDst"] = (a0, a1, a2, a3, a4) => (_mclBnG1_hashAndMapToWithDst = Module["_mclBnG1_hashAndMapToWithDst"] = wasmExports["mclBnG1_hashAndMapToWithDst"])(a0, a1, a2, a3, a4);

var _mclBnG1_getStr = Module["_mclBnG1_getStr"] = (a0, a1, a2, a3) => (_mclBnG1_getStr = Module["_mclBnG1_getStr"] = wasmExports["mclBnG1_getStr"])(a0, a1, a2, a3);

var _mclBnG1_serialize = Module["_mclBnG1_serialize"] = (a0, a1, a2) => (_mclBnG1_serialize = Module["_mclBnG1_serialize"] = wasmExports["mclBnG1_serialize"])(a0, a1, a2);

var _mclBnG1_neg = Module["_mclBnG1_neg"] = (a0, a1) => (_mclBnG1_neg = Module["_mclBnG1_neg"] = wasmExports["mclBnG1_neg"])(a0, a1);

var _mclBnG1_dbl = Module["_mclBnG1_dbl"] = (a0, a1) => (_mclBnG1_dbl = Module["_mclBnG1_dbl"] = wasmExports["mclBnG1_dbl"])(a0, a1);

var _mclBnG1_normalize = Module["_mclBnG1_normalize"] = (a0, a1) => (_mclBnG1_normalize = Module["_mclBnG1_normalize"] = wasmExports["mclBnG1_normalize"])(a0, a1);

var _mclBnG1_add = Module["_mclBnG1_add"] = (a0, a1, a2) => (_mclBnG1_add = Module["_mclBnG1_add"] = wasmExports["mclBnG1_add"])(a0, a1, a2);

var _mclBnG1_sub = Module["_mclBnG1_sub"] = (a0, a1, a2) => (_mclBnG1_sub = Module["_mclBnG1_sub"] = wasmExports["mclBnG1_sub"])(a0, a1, a2);

var _mclBnG1_mul = Module["_mclBnG1_mul"] = (a0, a1, a2) => (_mclBnG1_mul = Module["_mclBnG1_mul"] = wasmExports["mclBnG1_mul"])(a0, a1, a2);

var _mclBnG1_mulCT = Module["_mclBnG1_mulCT"] = (a0, a1, a2) => (_mclBnG1_mulCT = Module["_mclBnG1_mulCT"] = wasmExports["mclBnG1_mulCT"])(a0, a1, a2);

var _mclBnG2_clear = Module["_mclBnG2_clear"] = a0 => (_mclBnG2_clear = Module["_mclBnG2_clear"] = wasmExports["mclBnG2_clear"])(a0);

var _mclBnG2_setStr = Module["_mclBnG2_setStr"] = (a0, a1, a2, a3) => (_mclBnG2_setStr = Module["_mclBnG2_setStr"] = wasmExports["mclBnG2_setStr"])(a0, a1, a2, a3);

var _mclBnG2_deserialize = Module["_mclBnG2_deserialize"] = (a0, a1, a2) => (_mclBnG2_deserialize = Module["_mclBnG2_deserialize"] = wasmExports["mclBnG2_deserialize"])(a0, a1, a2);

var _mclBnG2_isValid = Module["_mclBnG2_isValid"] = a0 => (_mclBnG2_isValid = Module["_mclBnG2_isValid"] = wasmExports["mclBnG2_isValid"])(a0);

var _mclBnG2_isEqual = Module["_mclBnG2_isEqual"] = (a0, a1) => (_mclBnG2_isEqual = Module["_mclBnG2_isEqual"] = wasmExports["mclBnG2_isEqual"])(a0, a1);

var _mclBnG2_isZero = Module["_mclBnG2_isZero"] = a0 => (_mclBnG2_isZero = Module["_mclBnG2_isZero"] = wasmExports["mclBnG2_isZero"])(a0);

var _mclBnG2_isValidOrder = Module["_mclBnG2_isValidOrder"] = a0 => (_mclBnG2_isValidOrder = Module["_mclBnG2_isValidOrder"] = wasmExports["mclBnG2_isValidOrder"])(a0);

var _mclBnG2_hashAndMapTo = Module["_mclBnG2_hashAndMapTo"] = (a0, a1, a2) => (_mclBnG2_hashAndMapTo = Module["_mclBnG2_hashAndMapTo"] = wasmExports["mclBnG2_hashAndMapTo"])(a0, a1, a2);

var _mclBnG2_hashAndMapToWithDst = Module["_mclBnG2_hashAndMapToWithDst"] = (a0, a1, a2, a3, a4) => (_mclBnG2_hashAndMapToWithDst = Module["_mclBnG2_hashAndMapToWithDst"] = wasmExports["mclBnG2_hashAndMapToWithDst"])(a0, a1, a2, a3, a4);

var _mclBnG2_getStr = Module["_mclBnG2_getStr"] = (a0, a1, a2, a3) => (_mclBnG2_getStr = Module["_mclBnG2_getStr"] = wasmExports["mclBnG2_getStr"])(a0, a1, a2, a3);

var _mclBnG2_serialize = Module["_mclBnG2_serialize"] = (a0, a1, a2) => (_mclBnG2_serialize = Module["_mclBnG2_serialize"] = wasmExports["mclBnG2_serialize"])(a0, a1, a2);

var _mclBnG2_neg = Module["_mclBnG2_neg"] = (a0, a1) => (_mclBnG2_neg = Module["_mclBnG2_neg"] = wasmExports["mclBnG2_neg"])(a0, a1);

var _mclBnG2_dbl = Module["_mclBnG2_dbl"] = (a0, a1) => (_mclBnG2_dbl = Module["_mclBnG2_dbl"] = wasmExports["mclBnG2_dbl"])(a0, a1);

var _mclBnG2_normalize = Module["_mclBnG2_normalize"] = (a0, a1) => (_mclBnG2_normalize = Module["_mclBnG2_normalize"] = wasmExports["mclBnG2_normalize"])(a0, a1);

var _mclBnG2_add = Module["_mclBnG2_add"] = (a0, a1, a2) => (_mclBnG2_add = Module["_mclBnG2_add"] = wasmExports["mclBnG2_add"])(a0, a1, a2);

var _mclBnG2_sub = Module["_mclBnG2_sub"] = (a0, a1, a2) => (_mclBnG2_sub = Module["_mclBnG2_sub"] = wasmExports["mclBnG2_sub"])(a0, a1, a2);

var _mclBnG2_mul = Module["_mclBnG2_mul"] = (a0, a1, a2) => (_mclBnG2_mul = Module["_mclBnG2_mul"] = wasmExports["mclBnG2_mul"])(a0, a1, a2);

var _mclBnG2_mulCT = Module["_mclBnG2_mulCT"] = (a0, a1, a2) => (_mclBnG2_mulCT = Module["_mclBnG2_mulCT"] = wasmExports["mclBnG2_mulCT"])(a0, a1, a2);

var _mclBnGT_clear = Module["_mclBnGT_clear"] = a0 => (_mclBnGT_clear = Module["_mclBnGT_clear"] = wasmExports["mclBnGT_clear"])(a0);

var _mclBnGT_setInt = Module["_mclBnGT_setInt"] = (a0, a1) => (_mclBnGT_setInt = Module["_mclBnGT_setInt"] = wasmExports["mclBnGT_setInt"])(a0, a1);

var _mclBnGT_setInt32 = Module["_mclBnGT_setInt32"] = (a0, a1) => (_mclBnGT_setInt32 = Module["_mclBnGT_setInt32"] = wasmExports["mclBnGT_setInt32"])(a0, a1);

var _mclBnGT_setStr = Module["_mclBnGT_setStr"] = (a0, a1, a2, a3) => (_mclBnGT_setStr = Module["_mclBnGT_setStr"] = wasmExports["mclBnGT_setStr"])(a0, a1, a2, a3);

var _mclBnGT_deserialize = Module["_mclBnGT_deserialize"] = (a0, a1, a2) => (_mclBnGT_deserialize = Module["_mclBnGT_deserialize"] = wasmExports["mclBnGT_deserialize"])(a0, a1, a2);

var _mclBnGT_isEqual = Module["_mclBnGT_isEqual"] = (a0, a1) => (_mclBnGT_isEqual = Module["_mclBnGT_isEqual"] = wasmExports["mclBnGT_isEqual"])(a0, a1);

var _mclBnGT_isZero = Module["_mclBnGT_isZero"] = a0 => (_mclBnGT_isZero = Module["_mclBnGT_isZero"] = wasmExports["mclBnGT_isZero"])(a0);

var _mclBnGT_isOne = Module["_mclBnGT_isOne"] = a0 => (_mclBnGT_isOne = Module["_mclBnGT_isOne"] = wasmExports["mclBnGT_isOne"])(a0);

var _mclBnGT_isValid = Module["_mclBnGT_isValid"] = a0 => (_mclBnGT_isValid = Module["_mclBnGT_isValid"] = wasmExports["mclBnGT_isValid"])(a0);

var _mclBnGT_getStr = Module["_mclBnGT_getStr"] = (a0, a1, a2, a3) => (_mclBnGT_getStr = Module["_mclBnGT_getStr"] = wasmExports["mclBnGT_getStr"])(a0, a1, a2, a3);

var _mclBnGT_serialize = Module["_mclBnGT_serialize"] = (a0, a1, a2) => (_mclBnGT_serialize = Module["_mclBnGT_serialize"] = wasmExports["mclBnGT_serialize"])(a0, a1, a2);

var _mclBnGT_neg = Module["_mclBnGT_neg"] = (a0, a1) => (_mclBnGT_neg = Module["_mclBnGT_neg"] = wasmExports["mclBnGT_neg"])(a0, a1);

var _mclBnGT_inv = Module["_mclBnGT_inv"] = (a0, a1) => (_mclBnGT_inv = Module["_mclBnGT_inv"] = wasmExports["mclBnGT_inv"])(a0, a1);

var _mclBnGT_invGeneric = Module["_mclBnGT_invGeneric"] = (a0, a1) => (_mclBnGT_invGeneric = Module["_mclBnGT_invGeneric"] = wasmExports["mclBnGT_invGeneric"])(a0, a1);

var _mclBnGT_sqr = Module["_mclBnGT_sqr"] = (a0, a1) => (_mclBnGT_sqr = Module["_mclBnGT_sqr"] = wasmExports["mclBnGT_sqr"])(a0, a1);

var _mclBnGT_add = Module["_mclBnGT_add"] = (a0, a1, a2) => (_mclBnGT_add = Module["_mclBnGT_add"] = wasmExports["mclBnGT_add"])(a0, a1, a2);

var _mclBnGT_sub = Module["_mclBnGT_sub"] = (a0, a1, a2) => (_mclBnGT_sub = Module["_mclBnGT_sub"] = wasmExports["mclBnGT_sub"])(a0, a1, a2);

var _mclBnGT_mul = Module["_mclBnGT_mul"] = (a0, a1, a2) => (_mclBnGT_mul = Module["_mclBnGT_mul"] = wasmExports["mclBnGT_mul"])(a0, a1, a2);

var _mclBnGT_div = Module["_mclBnGT_div"] = (a0, a1, a2) => (_mclBnGT_div = Module["_mclBnGT_div"] = wasmExports["mclBnGT_div"])(a0, a1, a2);

var _mclBnGT_pow = Module["_mclBnGT_pow"] = (a0, a1, a2) => (_mclBnGT_pow = Module["_mclBnGT_pow"] = wasmExports["mclBnGT_pow"])(a0, a1, a2);

var _mclBnGT_powGeneric = Module["_mclBnGT_powGeneric"] = (a0, a1, a2) => (_mclBnGT_powGeneric = Module["_mclBnGT_powGeneric"] = wasmExports["mclBnGT_powGeneric"])(a0, a1, a2);

var _mclBnG1_mulVec = Module["_mclBnG1_mulVec"] = (a0, a1, a2, a3) => (_mclBnG1_mulVec = Module["_mclBnG1_mulVec"] = wasmExports["mclBnG1_mulVec"])(a0, a1, a2, a3);

var _mclBnG2_mulVec = Module["_mclBnG2_mulVec"] = (a0, a1, a2, a3) => (_mclBnG2_mulVec = Module["_mclBnG2_mulVec"] = wasmExports["mclBnG2_mulVec"])(a0, a1, a2, a3);

var _mclBnGT_powVec = Module["_mclBnGT_powVec"] = (a0, a1, a2, a3) => (_mclBnGT_powVec = Module["_mclBnGT_powVec"] = wasmExports["mclBnGT_powVec"])(a0, a1, a2, a3);

var _mclBnG1_mulEach = Module["_mclBnG1_mulEach"] = (a0, a1, a2) => (_mclBnG1_mulEach = Module["_mclBnG1_mulEach"] = wasmExports["mclBnG1_mulEach"])(a0, a1, a2);

var _mclBn_pairing = Module["_mclBn_pairing"] = (a0, a1, a2) => (_mclBn_pairing = Module["_mclBn_pairing"] = wasmExports["mclBn_pairing"])(a0, a1, a2);

var _mclBn_finalExp = Module["_mclBn_finalExp"] = (a0, a1) => (_mclBn_finalExp = Module["_mclBn_finalExp"] = wasmExports["mclBn_finalExp"])(a0, a1);

var _mclBn_millerLoop = Module["_mclBn_millerLoop"] = (a0, a1, a2) => (_mclBn_millerLoop = Module["_mclBn_millerLoop"] = wasmExports["mclBn_millerLoop"])(a0, a1, a2);

var _mclBn_millerLoopVec = Module["_mclBn_millerLoopVec"] = (a0, a1, a2, a3) => (_mclBn_millerLoopVec = Module["_mclBn_millerLoopVec"] = wasmExports["mclBn_millerLoopVec"])(a0, a1, a2, a3);

var _mclBn_millerLoopVecMT = Module["_mclBn_millerLoopVecMT"] = (a0, a1, a2, a3, a4) => (_mclBn_millerLoopVecMT = Module["_mclBn_millerLoopVecMT"] = wasmExports["mclBn_millerLoopVecMT"])(a0, a1, a2, a3, a4);

var _mclBnG1_mulVecMT = Module["_mclBnG1_mulVecMT"] = (a0, a1, a2, a3, a4) => (_mclBnG1_mulVecMT = Module["_mclBnG1_mulVecMT"] = wasmExports["mclBnG1_mulVecMT"])(a0, a1, a2, a3, a4);

var _mclBnG2_mulVecMT = Module["_mclBnG2_mulVecMT"] = (a0, a1, a2, a3, a4) => (_mclBnG2_mulVecMT = Module["_mclBnG2_mulVecMT"] = wasmExports["mclBnG2_mulVecMT"])(a0, a1, a2, a3, a4);

var _mclBn_getUint64NumToPrecompute = Module["_mclBn_getUint64NumToPrecompute"] = () => (_mclBn_getUint64NumToPrecompute = Module["_mclBn_getUint64NumToPrecompute"] = wasmExports["mclBn_getUint64NumToPrecompute"])();

var _mclBn_precomputeG2 = Module["_mclBn_precomputeG2"] = (a0, a1) => (_mclBn_precomputeG2 = Module["_mclBn_precomputeG2"] = wasmExports["mclBn_precomputeG2"])(a0, a1);

var _mclBn_precomputedMillerLoop = Module["_mclBn_precomputedMillerLoop"] = (a0, a1, a2) => (_mclBn_precomputedMillerLoop = Module["_mclBn_precomputedMillerLoop"] = wasmExports["mclBn_precomputedMillerLoop"])(a0, a1, a2);

var _mclBn_precomputedMillerLoop2 = Module["_mclBn_precomputedMillerLoop2"] = (a0, a1, a2, a3, a4) => (_mclBn_precomputedMillerLoop2 = Module["_mclBn_precomputedMillerLoop2"] = wasmExports["mclBn_precomputedMillerLoop2"])(a0, a1, a2, a3, a4);

var _mclBn_precomputedMillerLoop2mixed = Module["_mclBn_precomputedMillerLoop2mixed"] = (a0, a1, a2, a3, a4) => (_mclBn_precomputedMillerLoop2mixed = Module["_mclBn_precomputedMillerLoop2mixed"] = wasmExports["mclBn_precomputedMillerLoop2mixed"])(a0, a1, a2, a3, a4);

var _mclBn_FrLagrangeInterpolation = Module["_mclBn_FrLagrangeInterpolation"] = (a0, a1, a2, a3) => (_mclBn_FrLagrangeInterpolation = Module["_mclBn_FrLagrangeInterpolation"] = wasmExports["mclBn_FrLagrangeInterpolation"])(a0, a1, a2, a3);

var _mclBn_G1LagrangeInterpolation = Module["_mclBn_G1LagrangeInterpolation"] = (a0, a1, a2, a3) => (_mclBn_G1LagrangeInterpolation = Module["_mclBn_G1LagrangeInterpolation"] = wasmExports["mclBn_G1LagrangeInterpolation"])(a0, a1, a2, a3);

var _mclBn_G2LagrangeInterpolation = Module["_mclBn_G2LagrangeInterpolation"] = (a0, a1, a2, a3) => (_mclBn_G2LagrangeInterpolation = Module["_mclBn_G2LagrangeInterpolation"] = wasmExports["mclBn_G2LagrangeInterpolation"])(a0, a1, a2, a3);

var _mclBn_FrEvaluatePolynomial = Module["_mclBn_FrEvaluatePolynomial"] = (a0, a1, a2, a3) => (_mclBn_FrEvaluatePolynomial = Module["_mclBn_FrEvaluatePolynomial"] = wasmExports["mclBn_FrEvaluatePolynomial"])(a0, a1, a2, a3);

var _mclBn_G1EvaluatePolynomial = Module["_mclBn_G1EvaluatePolynomial"] = (a0, a1, a2, a3) => (_mclBn_G1EvaluatePolynomial = Module["_mclBn_G1EvaluatePolynomial"] = wasmExports["mclBn_G1EvaluatePolynomial"])(a0, a1, a2, a3);

var _mclBn_G2EvaluatePolynomial = Module["_mclBn_G2EvaluatePolynomial"] = (a0, a1, a2, a3) => (_mclBn_G2EvaluatePolynomial = Module["_mclBn_G2EvaluatePolynomial"] = wasmExports["mclBn_G2EvaluatePolynomial"])(a0, a1, a2, a3);

var _mclBn_verifyOrderG1 = Module["_mclBn_verifyOrderG1"] = a0 => (_mclBn_verifyOrderG1 = Module["_mclBn_verifyOrderG1"] = wasmExports["mclBn_verifyOrderG1"])(a0);

var _mclBn_verifyOrderG2 = Module["_mclBn_verifyOrderG2"] = a0 => (_mclBn_verifyOrderG2 = Module["_mclBn_verifyOrderG2"] = wasmExports["mclBn_verifyOrderG2"])(a0);

var _mclBnFp_setInt = Module["_mclBnFp_setInt"] = (a0, a1) => (_mclBnFp_setInt = Module["_mclBnFp_setInt"] = wasmExports["mclBnFp_setInt"])(a0, a1);

var _mclBnFp_setInt32 = Module["_mclBnFp_setInt32"] = (a0, a1) => (_mclBnFp_setInt32 = Module["_mclBnFp_setInt32"] = wasmExports["mclBnFp_setInt32"])(a0, a1);

var _mclBnFp_getStr = Module["_mclBnFp_getStr"] = (a0, a1, a2, a3) => (_mclBnFp_getStr = Module["_mclBnFp_getStr"] = wasmExports["mclBnFp_getStr"])(a0, a1, a2, a3);

var _mclBnFp_setStr = Module["_mclBnFp_setStr"] = (a0, a1, a2, a3) => (_mclBnFp_setStr = Module["_mclBnFp_setStr"] = wasmExports["mclBnFp_setStr"])(a0, a1, a2, a3);

var _mclBnFp_deserialize = Module["_mclBnFp_deserialize"] = (a0, a1, a2) => (_mclBnFp_deserialize = Module["_mclBnFp_deserialize"] = wasmExports["mclBnFp_deserialize"])(a0, a1, a2);

var _mclBnFp_serialize = Module["_mclBnFp_serialize"] = (a0, a1, a2) => (_mclBnFp_serialize = Module["_mclBnFp_serialize"] = wasmExports["mclBnFp_serialize"])(a0, a1, a2);

var _mclBnFp_clear = Module["_mclBnFp_clear"] = a0 => (_mclBnFp_clear = Module["_mclBnFp_clear"] = wasmExports["mclBnFp_clear"])(a0);

var _mclBnFp_setLittleEndian = Module["_mclBnFp_setLittleEndian"] = (a0, a1, a2) => (_mclBnFp_setLittleEndian = Module["_mclBnFp_setLittleEndian"] = wasmExports["mclBnFp_setLittleEndian"])(a0, a1, a2);

var _mclBnFp_setLittleEndianMod = Module["_mclBnFp_setLittleEndianMod"] = (a0, a1, a2) => (_mclBnFp_setLittleEndianMod = Module["_mclBnFp_setLittleEndianMod"] = wasmExports["mclBnFp_setLittleEndianMod"])(a0, a1, a2);

var _mclBnFp_setBigEndianMod = Module["_mclBnFp_setBigEndianMod"] = (a0, a1, a2) => (_mclBnFp_setBigEndianMod = Module["_mclBnFp_setBigEndianMod"] = wasmExports["mclBnFp_setBigEndianMod"])(a0, a1, a2);

var _mclBnFp_getLittleEndian = Module["_mclBnFp_getLittleEndian"] = (a0, a1, a2) => (_mclBnFp_getLittleEndian = Module["_mclBnFp_getLittleEndian"] = wasmExports["mclBnFp_getLittleEndian"])(a0, a1, a2);

var _mclBnFp_isValid = Module["_mclBnFp_isValid"] = a0 => (_mclBnFp_isValid = Module["_mclBnFp_isValid"] = wasmExports["mclBnFp_isValid"])(a0);

var _mclBnFp_isEqual = Module["_mclBnFp_isEqual"] = (a0, a1) => (_mclBnFp_isEqual = Module["_mclBnFp_isEqual"] = wasmExports["mclBnFp_isEqual"])(a0, a1);

var _mclBnFp_isZero = Module["_mclBnFp_isZero"] = a0 => (_mclBnFp_isZero = Module["_mclBnFp_isZero"] = wasmExports["mclBnFp_isZero"])(a0);

var _mclBnFp_isOne = Module["_mclBnFp_isOne"] = a0 => (_mclBnFp_isOne = Module["_mclBnFp_isOne"] = wasmExports["mclBnFp_isOne"])(a0);

var _mclBnFp_isOdd = Module["_mclBnFp_isOdd"] = a0 => (_mclBnFp_isOdd = Module["_mclBnFp_isOdd"] = wasmExports["mclBnFp_isOdd"])(a0);

var _mclBnFp_isNegative = Module["_mclBnFp_isNegative"] = a0 => (_mclBnFp_isNegative = Module["_mclBnFp_isNegative"] = wasmExports["mclBnFp_isNegative"])(a0);

var _mclBnFp_cmp = Module["_mclBnFp_cmp"] = (a0, a1) => (_mclBnFp_cmp = Module["_mclBnFp_cmp"] = wasmExports["mclBnFp_cmp"])(a0, a1);

var _mclBnFp_setHashOf = Module["_mclBnFp_setHashOf"] = (a0, a1, a2) => (_mclBnFp_setHashOf = Module["_mclBnFp_setHashOf"] = wasmExports["mclBnFp_setHashOf"])(a0, a1, a2);

var _mclBnFp_mapToG1 = Module["_mclBnFp_mapToG1"] = (a0, a1) => (_mclBnFp_mapToG1 = Module["_mclBnFp_mapToG1"] = wasmExports["mclBnFp_mapToG1"])(a0, a1);

var _mclBnFp2_deserialize = Module["_mclBnFp2_deserialize"] = (a0, a1, a2) => (_mclBnFp2_deserialize = Module["_mclBnFp2_deserialize"] = wasmExports["mclBnFp2_deserialize"])(a0, a1, a2);

var _mclBnFp2_serialize = Module["_mclBnFp2_serialize"] = (a0, a1, a2) => (_mclBnFp2_serialize = Module["_mclBnFp2_serialize"] = wasmExports["mclBnFp2_serialize"])(a0, a1, a2);

var _mclBnFp2_clear = Module["_mclBnFp2_clear"] = a0 => (_mclBnFp2_clear = Module["_mclBnFp2_clear"] = wasmExports["mclBnFp2_clear"])(a0);

var _mclBnFp2_isEqual = Module["_mclBnFp2_isEqual"] = (a0, a1) => (_mclBnFp2_isEqual = Module["_mclBnFp2_isEqual"] = wasmExports["mclBnFp2_isEqual"])(a0, a1);

var _mclBnFp2_isZero = Module["_mclBnFp2_isZero"] = a0 => (_mclBnFp2_isZero = Module["_mclBnFp2_isZero"] = wasmExports["mclBnFp2_isZero"])(a0);

var _mclBnFp2_isOne = Module["_mclBnFp2_isOne"] = a0 => (_mclBnFp2_isOne = Module["_mclBnFp2_isOne"] = wasmExports["mclBnFp2_isOne"])(a0);

var _mclBnFp2_mapToG2 = Module["_mclBnFp2_mapToG2"] = (a0, a1) => (_mclBnFp2_mapToG2 = Module["_mclBnFp2_mapToG2"] = wasmExports["mclBnFp2_mapToG2"])(a0, a1);

var _mclBnG1_getBasePoint = Module["_mclBnG1_getBasePoint"] = a0 => (_mclBnG1_getBasePoint = Module["_mclBnG1_getBasePoint"] = wasmExports["mclBnG1_getBasePoint"])(a0);

var _mclBnFr_pow = Module["_mclBnFr_pow"] = (a0, a1, a2) => (_mclBnFr_pow = Module["_mclBnFr_pow"] = wasmExports["mclBnFr_pow"])(a0, a1, a2);

var _mclBnFp_pow = Module["_mclBnFp_pow"] = (a0, a1, a2) => (_mclBnFp_pow = Module["_mclBnFp_pow"] = wasmExports["mclBnFp_pow"])(a0, a1, a2);

var _mclBnFr_powArray = Module["_mclBnFr_powArray"] = (a0, a1, a2, a3) => (_mclBnFr_powArray = Module["_mclBnFr_powArray"] = wasmExports["mclBnFr_powArray"])(a0, a1, a2, a3);

var _mclBnFp_powArray = Module["_mclBnFp_powArray"] = (a0, a1, a2, a3) => (_mclBnFp_powArray = Module["_mclBnFp_powArray"] = wasmExports["mclBnFp_powArray"])(a0, a1, a2, a3);

var _mclBnFr_invVec = Module["_mclBnFr_invVec"] = (a0, a1, a2) => (_mclBnFr_invVec = Module["_mclBnFr_invVec"] = wasmExports["mclBnFr_invVec"])(a0, a1, a2);

var _mclBnFp_invVec = Module["_mclBnFp_invVec"] = (a0, a1, a2) => (_mclBnFp_invVec = Module["_mclBnFp_invVec"] = wasmExports["mclBnFp_invVec"])(a0, a1, a2);

var _mclBnG1_normalizeVec = Module["_mclBnG1_normalizeVec"] = (a0, a1, a2) => (_mclBnG1_normalizeVec = Module["_mclBnG1_normalizeVec"] = wasmExports["mclBnG1_normalizeVec"])(a0, a1, a2);

var _mclBnG2_normalizeVec = Module["_mclBnG2_normalizeVec"] = (a0, a1, a2) => (_mclBnG2_normalizeVec = Module["_mclBnG2_normalizeVec"] = wasmExports["mclBnG2_normalizeVec"])(a0, a1, a2);

var _eth_blockNumber = Module["_eth_blockNumber"] = (a0, a1, a2) => (_eth_blockNumber = Module["_eth_blockNumber"] = wasmExports["eth_blockNumber"])(a0, a1, a2);

var _eth_getBalance = Module["_eth_getBalance"] = (a0, a1, a2, a3, a4) => (_eth_getBalance = Module["_eth_getBalance"] = wasmExports["eth_getBalance"])(a0, a1, a2, a3, a4);

var _eth_getStorageAt = Module["_eth_getStorageAt"] = (a0, a1, a2, a3, a4, a5) => (_eth_getStorageAt = Module["_eth_getStorageAt"] = wasmExports["eth_getStorageAt"])(a0, a1, a2, a3, a4, a5);

var _eth_getTransactionCount = Module["_eth_getTransactionCount"] = (a0, a1, a2, a3, a4) => (_eth_getTransactionCount = Module["_eth_getTransactionCount"] = wasmExports["eth_getTransactionCount"])(a0, a1, a2, a3, a4);

var _eth_getCode = Module["_eth_getCode"] = (a0, a1, a2, a3, a4) => (_eth_getCode = Module["_eth_getCode"] = wasmExports["eth_getCode"])(a0, a1, a2, a3, a4);

var _eth_getBlockByHash = Module["_eth_getBlockByHash"] = (a0, a1, a2, a3, a4) => (_eth_getBlockByHash = Module["_eth_getBlockByHash"] = wasmExports["eth_getBlockByHash"])(a0, a1, a2, a3, a4);

var _eth_getBlockByNumber = Module["_eth_getBlockByNumber"] = (a0, a1, a2, a3, a4) => (_eth_getBlockByNumber = Module["_eth_getBlockByNumber"] = wasmExports["eth_getBlockByNumber"])(a0, a1, a2, a3, a4);

var _eth_getUncleCountByBlockNumber = Module["_eth_getUncleCountByBlockNumber"] = (a0, a1, a2, a3) => (_eth_getUncleCountByBlockNumber = Module["_eth_getUncleCountByBlockNumber"] = wasmExports["eth_getUncleCountByBlockNumber"])(a0, a1, a2, a3);

var _eth_getUncleCountByBlockHash = Module["_eth_getUncleCountByBlockHash"] = (a0, a1, a2, a3) => (_eth_getUncleCountByBlockHash = Module["_eth_getUncleCountByBlockHash"] = wasmExports["eth_getUncleCountByBlockHash"])(a0, a1, a2, a3);

var _eth_getBlockTransactionCountByNumber = Module["_eth_getBlockTransactionCountByNumber"] = (a0, a1, a2, a3) => (_eth_getBlockTransactionCountByNumber = Module["_eth_getBlockTransactionCountByNumber"] = wasmExports["eth_getBlockTransactionCountByNumber"])(a0, a1, a2, a3);

var _eth_getBlockTransactionCountByHash = Module["_eth_getBlockTransactionCountByHash"] = (a0, a1, a2, a3) => (_eth_getBlockTransactionCountByHash = Module["_eth_getBlockTransactionCountByHash"] = wasmExports["eth_getBlockTransactionCountByHash"])(a0, a1, a2, a3);

var _eth_getTransactionByBlockNumberAndIndex = Module["_eth_getTransactionByBlockNumberAndIndex"] = (a0, a1, a2, a3, a4, a5) => (_eth_getTransactionByBlockNumberAndIndex = Module["_eth_getTransactionByBlockNumberAndIndex"] = wasmExports["eth_getTransactionByBlockNumberAndIndex"])(a0, a1, a2, a3, a4, a5);

var _eth_getTransactionByBlockHashAndIndex = Module["_eth_getTransactionByBlockHashAndIndex"] = (a0, a1, a2, a3, a4, a5) => (_eth_getTransactionByBlockHashAndIndex = Module["_eth_getTransactionByBlockHashAndIndex"] = wasmExports["eth_getTransactionByBlockHashAndIndex"])(a0, a1, a2, a3, a4, a5);

var _eth_call = Module["_eth_call"] = (a0, a1, a2, a3, a4, a5) => (_eth_call = Module["_eth_call"] = wasmExports["eth_call"])(a0, a1, a2, a3, a4, a5);

var _eth_createAccessList = Module["_eth_createAccessList"] = (a0, a1, a2, a3, a4, a5) => (_eth_createAccessList = Module["_eth_createAccessList"] = wasmExports["eth_createAccessList"])(a0, a1, a2, a3, a4, a5);

var _eth_estimateGas = Module["_eth_estimateGas"] = (a0, a1, a2, a3, a4, a5) => (_eth_estimateGas = Module["_eth_estimateGas"] = wasmExports["eth_estimateGas"])(a0, a1, a2, a3, a4, a5);

var _eth_getTransactionByHash = Module["_eth_getTransactionByHash"] = (a0, a1, a2, a3) => (_eth_getTransactionByHash = Module["_eth_getTransactionByHash"] = wasmExports["eth_getTransactionByHash"])(a0, a1, a2, a3);

var _eth_getBlockReceipts = Module["_eth_getBlockReceipts"] = (a0, a1, a2, a3) => (_eth_getBlockReceipts = Module["_eth_getBlockReceipts"] = wasmExports["eth_getBlockReceipts"])(a0, a1, a2, a3);

var _eth_getTransactionReceipt = Module["_eth_getTransactionReceipt"] = (a0, a1, a2, a3) => (_eth_getTransactionReceipt = Module["_eth_getTransactionReceipt"] = wasmExports["eth_getTransactionReceipt"])(a0, a1, a2, a3);

var _eth_getLogs = Module["_eth_getLogs"] = (a0, a1, a2, a3) => (_eth_getLogs = Module["_eth_getLogs"] = wasmExports["eth_getLogs"])(a0, a1, a2, a3);

var _eth_newFilter = Module["_eth_newFilter"] = (a0, a1, a2, a3) => (_eth_newFilter = Module["_eth_newFilter"] = wasmExports["eth_newFilter"])(a0, a1, a2, a3);

var _eth_uninstallFilter = Module["_eth_uninstallFilter"] = (a0, a1, a2, a3) => (_eth_uninstallFilter = Module["_eth_uninstallFilter"] = wasmExports["eth_uninstallFilter"])(a0, a1, a2, a3);

var _eth_getFilterLogs = Module["_eth_getFilterLogs"] = (a0, a1, a2, a3) => (_eth_getFilterLogs = Module["_eth_getFilterLogs"] = wasmExports["eth_getFilterLogs"])(a0, a1, a2, a3);

var _eth_getFilterChanges = Module["_eth_getFilterChanges"] = (a0, a1, a2, a3) => (_eth_getFilterChanges = Module["_eth_getFilterChanges"] = wasmExports["eth_getFilterChanges"])(a0, a1, a2, a3);

var _eth_blobBaseFee = Module["_eth_blobBaseFee"] = (a0, a1, a2) => (_eth_blobBaseFee = Module["_eth_blobBaseFee"] = wasmExports["eth_blobBaseFee"])(a0, a1, a2);

var _eth_gasPrice = Module["_eth_gasPrice"] = (a0, a1, a2) => (_eth_gasPrice = Module["_eth_gasPrice"] = wasmExports["eth_gasPrice"])(a0, a1, a2);

var _eth_maxPriorityFeePerGas = Module["_eth_maxPriorityFeePerGas"] = (a0, a1, a2) => (_eth_maxPriorityFeePerGas = Module["_eth_maxPriorityFeePerGas"] = wasmExports["eth_maxPriorityFeePerGas"])(a0, a1, a2);

var _eth_feeHistory = Module["_eth_feeHistory"] = (a0, a1, a2, a3, a4, a5, a6) => (_eth_feeHistory = Module["_eth_feeHistory"] = wasmExports["eth_feeHistory"])(a0, a1, a2, a3, a4, a5, a6);

var _eth_sendRawTransaction = Module["_eth_sendRawTransaction"] = (a0, a1, a2, a3) => (_eth_sendRawTransaction = Module["_eth_sendRawTransaction"] = wasmExports["eth_sendRawTransaction"])(a0, a1, a2, a3);

var __emscripten_tls_init = () => (__emscripten_tls_init = wasmExports["_emscripten_tls_init"])();

var _pthread_self = () => (_pthread_self = wasmExports["pthread_self"])();

var _emscripten_builtin_memalign = (a0, a1) => (_emscripten_builtin_memalign = wasmExports["emscripten_builtin_memalign"])(a0, a1);

var __emscripten_thread_init = (a0, a1, a2, a3, a4, a5) => (__emscripten_thread_init = wasmExports["_emscripten_thread_init"])(a0, a1, a2, a3, a4, a5);

var __emscripten_thread_crashed = () => (__emscripten_thread_crashed = wasmExports["_emscripten_thread_crashed"])();

var _emscripten_main_thread_process_queued_calls = () => (_emscripten_main_thread_process_queued_calls = wasmExports["emscripten_main_thread_process_queued_calls"])();

var _htonl = a0 => (_htonl = wasmExports["htonl"])(a0);

var _htons = a0 => (_htons = wasmExports["htons"])(a0);

var _emscripten_main_runtime_thread_id = () => (_emscripten_main_runtime_thread_id = wasmExports["emscripten_main_runtime_thread_id"])();

var _ntohs = a0 => (_ntohs = wasmExports["ntohs"])(a0);

var __emscripten_run_on_main_thread_js = (a0, a1, a2, a3, a4) => (__emscripten_run_on_main_thread_js = wasmExports["_emscripten_run_on_main_thread_js"])(a0, a1, a2, a3, a4);

var __emscripten_thread_free_data = a0 => (__emscripten_thread_free_data = wasmExports["_emscripten_thread_free_data"])(a0);

var __emscripten_thread_exit = a0 => (__emscripten_thread_exit = wasmExports["_emscripten_thread_exit"])(a0);

var __emscripten_timeout = (a0, a1) => (__emscripten_timeout = wasmExports["_emscripten_timeout"])(a0, a1);

var __emscripten_check_mailbox = () => (__emscripten_check_mailbox = wasmExports["_emscripten_check_mailbox"])();

var __emscripten_tempret_set = a0 => (__emscripten_tempret_set = wasmExports["_emscripten_tempret_set"])(a0);

var _emscripten_stack_set_limits = (a0, a1) => (_emscripten_stack_set_limits = wasmExports["emscripten_stack_set_limits"])(a0, a1);

var __emscripten_stack_restore = a0 => (__emscripten_stack_restore = wasmExports["_emscripten_stack_restore"])(a0);

var __emscripten_stack_alloc = a0 => (__emscripten_stack_alloc = wasmExports["_emscripten_stack_alloc"])(a0);

var _emscripten_stack_get_current = () => (_emscripten_stack_get_current = wasmExports["emscripten_stack_get_current"])();

var ___cxa_increment_exception_refcount = a0 => (___cxa_increment_exception_refcount = wasmExports["__cxa_increment_exception_refcount"])(a0);

var dynCall_ji = Module["dynCall_ji"] = (a0, a1) => (dynCall_ji = Module["dynCall_ji"] = wasmExports["dynCall_ji"])(a0, a1);

var dynCall_jii = Module["dynCall_jii"] = (a0, a1, a2) => (dynCall_jii = Module["dynCall_jii"] = wasmExports["dynCall_jii"])(a0, a1, a2);

var dynCall_jiii = Module["dynCall_jiii"] = (a0, a1, a2, a3) => (dynCall_jiii = Module["dynCall_jiii"] = wasmExports["dynCall_jiii"])(a0, a1, a2, a3);

var dynCall_j = Module["dynCall_j"] = a0 => (dynCall_j = Module["dynCall_j"] = wasmExports["dynCall_j"])(a0);

var dynCall_iiji = Module["dynCall_iiji"] = (a0, a1, a2, a3, a4) => (dynCall_iiji = Module["dynCall_iiji"] = wasmExports["dynCall_iiji"])(a0, a1, a2, a3, a4);

var dynCall_ijiii = Module["dynCall_ijiii"] = (a0, a1, a2, a3, a4, a5) => (dynCall_ijiii = Module["dynCall_ijiii"] = wasmExports["dynCall_ijiii"])(a0, a1, a2, a3, a4, a5);

var dynCall_ijji = Module["dynCall_ijji"] = (a0, a1, a2, a3, a4, a5) => (dynCall_ijji = Module["dynCall_ijji"] = wasmExports["dynCall_ijji"])(a0, a1, a2, a3, a4, a5);

var dynCall_viij = Module["dynCall_viij"] = (a0, a1, a2, a3, a4) => (dynCall_viij = Module["dynCall_viij"] = wasmExports["dynCall_viij"])(a0, a1, a2, a3, a4);

var dynCall_jiji = Module["dynCall_jiji"] = (a0, a1, a2, a3, a4) => (dynCall_jiji = Module["dynCall_jiji"] = wasmExports["dynCall_jiji"])(a0, a1, a2, a3, a4);

// include: postamble.js
// === Auto-generated postamble setup entry stuff ===
Module["ccall"] = ccall;

Module["cwrap"] = cwrap;

Module["addFunction"] = addFunction;

Module["removeFunction"] = removeFunction;

Module["UTF8ToString"] = UTF8ToString;

Module["stringToNewUTF8"] = stringToNewUTF8;

var calledRun;

dependenciesFulfilled = function runCaller() {
  // If run has never been called, and we should call run (INVOKE_RUN is true, and Module.noInitialRun is not false)
  if (!calledRun) run();
  if (!calledRun) dependenciesFulfilled = runCaller;
};

// try this again later, after new deps are fulfilled
function run() {
  if (runDependencies > 0) {
    return;
  }
  if (ENVIRONMENT_IS_PTHREAD) {
    // The promise resolve function typically gets called as part of the execution
    // of `doRun` below. The workers/pthreads don't execute `doRun` so the
    // creation promise can be resolved, marking the pthread-Module as initialized.
    readyPromiseResolve(Module);
    initRuntime();
    startWorker(Module);
    return;
  }
  preRun();
  // a preRun added a dependency, run will be called later
  if (runDependencies > 0) {
    return;
  }
  function doRun() {
    // run may have just been called through dependencies being fulfilled just in this very frame,
    // or while the async setStatus time below was happening
    if (calledRun) return;
    calledRun = true;
    Module["calledRun"] = true;
    if (ABORT) return;
    initRuntime();
    readyPromiseResolve(Module);
    Module["onRuntimeInitialized"]?.();
    postRun();
  }
  if (Module["setStatus"]) {
    Module["setStatus"]("Running...");
    setTimeout(() => {
      setTimeout(() => Module["setStatus"](""), 1);
      doRun();
    }, 1);
  } else {
    doRun();
  }
}

if (Module["preInit"]) {
  if (typeof Module["preInit"] == "function") Module["preInit"] = [ Module["preInit"] ];
  while (Module["preInit"].length > 0) {
    Module["preInit"].pop()();
  }
}

run();

// end include: postamble.js
// include: postamble_modularize.js
// In MODULARIZE mode we wrap the generated code in a factory function
// and return either the Module itself, or a promise of the module.
// We assign to the `moduleRtn` global here and configure closure to see
// this as and extern so it won't get minified.
moduleRtn = readyPromise;


  return moduleRtn;
}
);
})();
export default VerifProxyModule;
var isPthread = globalThis.self?.name?.startsWith('em-pthread');
var isNode = typeof globalThis.process?.versions?.node == 'string';
if (isNode) isPthread = (await import('worker_threads')).workerData === 'em-pthread';

// When running as a pthread, construct a new instance on startup
isPthread && VerifProxyModule();
