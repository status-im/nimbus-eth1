/**
 * nimbus_verified_proxy
 * Copyright (c) 2026 Status Research & Development GmbH
 * Licensed and distributed under either of
 *   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
 *   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
 * at your option. This file may not be copied, modified, or distributed except according to those terms.
 */

#include <stdint.h>
#include <emscripten.h>
#include "./verifproxy.h"

static Context *g_ctx = NULL;

/* --------------------------------------------------------------------------
 * Internal: transport proc — delegates to JS asynchronously.
 * Does NOT call cb; JS makes the async fetch and later calls
 * wasm_deliver_transport to resume the Nim future.
 * params ownership is transferred to JS; JS must free via _freeNimAllocatedString.
 * -------------------------------------------------------------------------- */
static void wasm_transport(Context *ctx, char *url, char *name, char *params,
                           CallBackProc cb, void *userData) {
    EM_ASM({ Module.verifProxyTransport($0, $1, $2, $3, $4, $5); },
           ctx, url, name, params, cb, userData);
    /* params ownership transferred to JS; JS frees via _freeNimAllocatedString */
}

/* --------------------------------------------------------------------------
 * Internal: generic CallBackProc for all API calls.
 * Notifies JS synchronously via EM_ASM (JS reads the result string while the
 * pointer is still valid), then frees the Nim-owned result string.
 * userData carries an integer callId cast to a pointer.
 * -------------------------------------------------------------------------- */
static void wasm_callback(Context *ctx, int status, char *res, void *userData) {
    EM_ASM({ Module.verifProxyCallback($0, $1, $2); },
           status, res, (int)(intptr_t)userData);
    freeNimAllocatedString(res);
}

/* --------------------------------------------------------------------------
 * Internal: main loop tick — called by emscripten on each frame.
 * Cancels the emscripten main loop when the proxy signals it has stopped.
 * -------------------------------------------------------------------------- */
static void main_loop(void) {
    if (g_ctx == NULL) return;
    int ret = processVerifProxyTasks(g_ctx);
    if (ret == RET_CANCELLED) {
        emscripten_cancel_main_loop();
    }
}

/* --------------------------------------------------------------------------
 * KEEPALIVE: initialise Nim, start the verified proxy, and register the
 * emscripten main loop callback (non-blocking — returns immediately to the
 * browser; the loop is driven by the browser's frame scheduler).
 * -------------------------------------------------------------------------- */
EMSCRIPTEN_KEEPALIVE
void wasm_start(char *configJson) {
    NimMain();
    g_ctx = startVerifProxy(configJson, wasm_transport, wasm_callback,
                            (void *)0 /* callId=0 reserved for startup */);
    emscripten_set_main_loop(main_loop, 0, 0);
}

/* --------------------------------------------------------------------------
 * KEEPALIVE: signal the running proxy to stop.
 * -------------------------------------------------------------------------- */
EMSCRIPTEN_KEEPALIVE
void wasm_stop(void) {
    if (g_ctx != NULL) {
        stopVerifProxy(g_ctx);
    }
}

/* --------------------------------------------------------------------------
 * KEEPALIVE: dispatch an RPC call through nvp_call.
 * callId is used by wasm_callback to route the response back to the correct
 * JS Promise (callId >= 1 for user calls; 0 is reserved for startup).
 * -------------------------------------------------------------------------- */
EMSCRIPTEN_KEEPALIVE
void wasm_call(char *name, char *params, int callId) {
    nvp_call(g_ctx, name, params, wasm_callback, (void *)(intptr_t)callId);
}

/* --------------------------------------------------------------------------
 * KEEPALIVE: called by JS when the async fetch resolves or rejects.
 * Directly invokes the original Nim transport callback (cb) with the fetch
 * result, resuming the Nim future. JS owns the result buffer and must free
 * it (via Module._free) after this function returns.
 * -------------------------------------------------------------------------- */
EMSCRIPTEN_KEEPALIVE
void wasm_deliver_transport(CallBackProc cb, Context *ctx, int status,
                            char *result, void *userData) {
    cb(ctx, status, result, userData);
}
