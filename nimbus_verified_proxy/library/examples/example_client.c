/**
 * nimbus_verified_proxy — minimal C client example
 * Copyright (c) 2026 Status Research & Development GmbH
 * Licensed under MIT or Apache-2.0 (see repository root).
 *
 * Compile (after building libverifproxy):
 *   gcc -I build/libverifproxy -L build/libverifproxy \
 *       -o example_client nimbus_verified_proxy/library/examples/example_client.c \
 *       -lverifproxy -lstdc++ -lm
 */

#include "verifproxy.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

/* ── Transport stubs ──────────────────────────────────────────────── */

/* Replace these with real HTTP calls in a production client. */
static void execution_transport(
    Context *ctx, TransportDeliveryCallback cb, void *userData
) {
    const char *name   = execCtxName(userData);
    const char *params = execCtxParams(userData);
    printf("[exec] %s %s\n", name, params);

    /* Return a minimal valid response so the proxy does not hang. */
    const char *stub = "\"0x0\"";
    cb(RET_SUCCESS, (char *)stub, userData);
}

static void beacon_transport(
    Context *ctx, TransportDeliveryCallback cb, void *userData
) {
    const char *endpoint = beaconCtxEndpoint(userData);
    printf("[beacon] %s\n", endpoint);
    cb(RET_ERROR, "stub — no real beacon transport", userData);
}

/* ── Callback ─────────────────────────────────────────────────────── */

typedef struct { bool fired; int status; char *body; } Result;

static void on_result(Context *ctx, int status, char *result, void *userData) {
    Result *r  = (Result *)userData;
    r->fired   = true;
    r->status  = status;
    r->body    = result ? strdup(result) : NULL;
    freeNimAllocatedString(result);
}

/* ── Main ─────────────────────────────────────────────────────────── */

int main(void) {
    NimMain();

    const char *config =
        "{"
        "  \"eth2Network\": \"mainnet\","
        "  \"trustedBlockRoot\": \"0x0000000000000000000000000000000000000000000000000000000000000000\","
        "  \"executionApiUrls\": \"http://127.0.0.1:8545\","
        "  \"beaconApiUrls\": \"http://127.0.0.1:5052\","
        "  \"logLevel\": \"FATAL\""
        "}";

    Context *ctx = startVerifProxy(config, execution_transport, beacon_transport);
    if (!ctx) {
        fprintf(stderr, "startVerifProxy failed\n");
        return 1;
    }

    Result r = {0};
    eth_blockNumber(ctx, on_result, &r);

    /* Drain the event loop until the callback fires. */
    for (int i = 0; i < 1000 && !r.fired; i++) {
        processVerifProxyTasks(ctx);
    }

    if (r.fired) {
        printf("eth_blockNumber → status=%d body=%s\n",
               r.status, r.body ? r.body : "(null)");
        free(r.body);
    } else {
        fprintf(stderr, "callback did not fire\n");
    }

    stopVerifProxy(ctx);
    freeContext(ctx);
    return 0;
}
