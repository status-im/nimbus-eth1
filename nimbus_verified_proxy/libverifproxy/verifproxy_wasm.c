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

static void main_loop(void) {
    if (g_ctx == NULL) return;
    int ret = processVerifProxyTasks(g_ctx);
    if (ret == RET_CANCELLED) {
        emscripten_cancel_main_loop();
    }
}

EMSCRIPTEN_KEEPALIVE
void nvp_start(char *configJson, CallBackProc cb, TransportProc transport) {
    NimMain();
    g_ctx = startVerifProxy(configJson, transport, cb, NULL);
    emscripten_set_main_loop(main_loop, 0, 0);
}

EMSCRIPTEN_KEEPALIVE
void nvp_free_string(char *res) {
    freeNimAllocatedString(res);
}

EMSCRIPTEN_KEEPALIVE
void nvp_stop(void) {
    if (g_ctx != NULL) {
        stopVerifProxy(g_ctx);
        emscripten_cancel_main_loop();
        freeContext(g_ctx);
        g_ctx = NULL;
    }
}

EMSCRIPTEN_KEEPALIVE
void nvp_wasm_call(char *name, char *params, CallBackProc cb) {
    nvp_call(g_ctx, name, params, cb, NULL);
}

EMSCRIPTEN_KEEPALIVE
void nvp_deliver_transport(CallBackProc cb, Context *ctx, int status, char *result, void *userData) {
    cb(ctx, status, result, userData);
}
