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
#include <time.h>

static void execution_transport(
    Context *ctx, TransportDeliveryCallback cb, void *userData
) {
    const char *name   = execCtxName(userData);
    const char *params = execCtxParams(userData);
    const char *url = execCtxUrl(userData);
    printf("[exec] url: %s, name: %s, params: %s\n", url, name, params);

    cb(RET_ERROR, "not implemented", userData);
}

static void beacon_transport(
    Context *ctx, TransportDeliveryCallback cb, void *userData
) {
    const char *params = beaconCtxParams(userData);
    const char *endpoint = beaconCtxEndpoint(userData);
    const char *url = beaconCtxUrl(userData);
    printf("[beacon] url: %s, endpoint: %s, params: %s\n", url, endpoint, params);
    cb(RET_ERROR, "not implemented", userData);
}

// This type collects the result after the callback is fired
// A pointer to this can be passed as userData for any call
// It would be passed back via the callback.
typedef struct { bool fired; int status; char *body; } Result;

// Callback:
// Collects the response in the userData that was passed back
static void on_result(Context *ctx, int status, char *result, void *userData) {
    Result *r  = (Result *)userData;
    r->fired   = true;
    r->status  = status;
    r->body    = result ? strdup(result) : NULL;
    freeNimAllocatedString(result);
}

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
    time_t now = time(NULL);

    while (true) {
        if ((time(NULL) - now) > 12) {
            now = time(NULL);
            // check if the previous callback fired?
            if (r.fired) {
                printf("eth_blockNumber: status=%d body=%s\n", r.status, r.body ? r.body : "(null)");
                free(r.body);
                r = (Result){0};
            } else {
                fprintf(stderr, "callback did not fire\n");
            }

            //launch new request
            eth_blockNumber(ctx, on_result, &r);
        }
        //keep polling
        if (processVerifProxyTasks(ctx) == RET_CANCELLED)
            break;
    }

    stopVerifProxy(ctx);
    freeContext(ctx);
    return 0;
}
