/**
 * nimbus_verified_proxy
 * Copyright (c) 2026 Status Research & Development GmbH
 * Licensed and distributed under either of
 *   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
 *   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
 * at your option. This file may not be copied, modified, or distributed except according to those terms.
 */

#include <stdint.h>
#include <stdio.h>
#include <emscripten.h>
#include "../../verifproxy.h"

static Context *g_ctx = NULL;

EMSCRIPTEN_KEEPALIVE
int wasmStart(
    char *configJson,
    ExecutionTransportProc executionTransport,
    BeaconTransportProc beaconTransport
) {
    NimMain();
    g_ctx = startVerifProxy(configJson, executionTransport, beaconTransport);

    if (g_ctx == NULL) return -1;

    return 0;
}

EMSCRIPTEN_KEEPALIVE
void wasmFreeString(char *res) {
    freeNimAllocatedString(res);
}

EMSCRIPTEN_KEEPALIVE
void wasmStop(void) {
    if (g_ctx != NULL) {
        stopVerifProxy(g_ctx);

        freeContext(g_ctx);
        g_ctx = NULL;
    }
}

EMSCRIPTEN_KEEPALIVE
void wasmCall(char *name, char *params, CallBackProc cb, void *userData) {
    proxyCall(g_ctx, name, params, cb, userData);
}

EMSCRIPTEN_KEEPALIVE
int wasmProcessTasks(void) {
    if (g_ctx == NULL) return RET_CANCELLED;
    return processVerifProxyTasks(g_ctx);
}

EMSCRIPTEN_KEEPALIVE
void wasmDeliverExecutionTransport(int status, char *result, void *userData) {
    deliverExecutionTransport(status, result, userData);
}

EMSCRIPTEN_KEEPALIVE
void wasmDeliverBeaconTransport(int status, char *result, void *userData) {
    deliverBeaconTransport(status, result, userData);
}

EMSCRIPTEN_KEEPALIVE const char *wasmExecCtxUrl(void *u) { return execCtxUrl(u); }
EMSCRIPTEN_KEEPALIVE const char *wasmExecCtxName(void *u) { return execCtxName(u); }
EMSCRIPTEN_KEEPALIVE const char *wasmExecCtxParams(void *u) { return execCtxParams(u); }
EMSCRIPTEN_KEEPALIVE const char *wasmBeaconCtxUrl(void *u) { return beaconCtxUrl(u); }
EMSCRIPTEN_KEEPALIVE const char *wasmBeaconCtxEndpoint(void *u) { return beaconCtxEndpoint(u); }
EMSCRIPTEN_KEEPALIVE const char *wasmBeaconCtxParams(void *u) { return beaconCtxParams(u); }
