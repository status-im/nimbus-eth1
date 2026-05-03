/**
 * nimbus_verified_proxy
 * Copyright (c) 2025-2026 Status Research & Development GmbH
 * Licensed and distributed under either of
 *   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
 *   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
 * at your option. This file may not be copied, modified, or distributed except according to those terms.
 */

#include "verifproxy.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

static int g_total  = 0;
static int g_passed = 0;

#define TEST(name, cond) do {                                              \
    g_total++;                                                             \
    if (cond) {                                                            \
        g_passed++;                                                        \
        printf("  PASS  %s\n", name);                                      \
    } else {                                                               \
        fprintf(stderr, "  FAIL  %s  (line %d)\n", name, __LINE__);       \
    }                                                                      \
} while (0)

typedef struct {
    bool called;
    int  status;
} CbState;

static void collect_error_cb(Context *ctx, int status, char *res, void *userData) {
    (void)ctx;
    CbState *s  = (CbState *)userData;
    s->called   = true;
    s->status   = status;

    if (status != RET_SUCCESS)
        fprintf(stdout, "  [cb] status=%d  res=%s\n", status, res ? res : "(null)");

    freeNimAllocatedString(res);
}

static const char *TEST_CONFIG =
    "{"
    "\"eth2Network\": \"mainnet\","
    "\"trustedBlockRoot\": \"0x9bcb90ec3a294591b77dd2a58e973578715cdc0e6eeeb286bc06dd120057f18b\","
    "\"executionApiUrls\": \"http://127.0.0.1:19999\","
    "\"beaconApiUrls\":    \"http://127.0.0.1:19998\","
    "\"logLevel\":         \"FATAL\","
    "\"logStdout\":        \"None\","
    "\"syncHeaderStore\": true,"
    "\"freezeAtSlot\": 14018020"
    "}";

// these errors are returned before the actual frontend method is called
// hence it is not required to poll the event loop
void check_deser_errors(Context *ctx) {
    printf("\n API params validation\n");
    CbState s;
    const char *VALID_ADDRESS = "0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC";
    const char *INVALID_ADDRESS = "not-a-address";
    const char *INVALID_HASH32 = "not-a-hash";
    const char *INVALID_UINT256 = "not-a-uint256";
    const char *VALID_UINT256 = "0x0";
    const char *INVALID_JSON = "not-valid-json{{{";

    s = (CbState){0};
    eth_getBalance(ctx, INVALID_ADDRESS, "latest", collect_error_cb, &s);
    TEST("eth_getBalance bad address: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    eth_getStorageAt(ctx, VALID_ADDRESS, INVALID_UINT256, "latest", collect_error_cb, &s);
    TEST("eth_getStorageAt bad slot: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    eth_getStorageAt(ctx, INVALID_ADDRESS, VALID_UINT256, "latest", collect_error_cb, &s);
    TEST("eth_getStorageAt bad address: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    eth_getTransactionCount(ctx, INVALID_ADDRESS, "latest", collect_error_cb, &s);
    TEST("eth_getTransactionCount bad address: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    eth_getCode(ctx, INVALID_ADDRESS, "latest", collect_error_cb, &s);
    TEST("eth_getCode bad address: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    eth_getBlockByHash(ctx, INVALID_HASH32, false, collect_error_cb, &s);
    TEST("eth_getBlockByHash short hash: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    eth_getUncleCountByBlockHash(ctx, INVALID_HASH32, collect_error_cb, &s);
    TEST("eth_getUncleCountByBlockHash bad hash: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    eth_getBlockTransactionCountByHash(ctx, INVALID_HASH32, collect_error_cb, &s);
    TEST("eth_getBlockTransactionCountByHash bad hash: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    eth_getTransactionByHash(ctx, INVALID_HASH32, collect_error_cb, &s);
    TEST("eth_getTransactionByHash bad hash: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    eth_getTransactionByBlockHashAndIndex(ctx, INVALID_HASH32, 0ULL, collect_error_cb, &s);
    TEST("eth_getTransactionByBlockHashAndIndex bad hash: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    eth_getTransactionReceipt(ctx, INVALID_HASH32, collect_error_cb, &s);
    TEST("eth_getTransactionReceipt bad hash: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    eth_sendRawTransaction(ctx, "not-hex-bytes", collect_error_cb, &s);
    TEST("eth_sendRawTransaction non-hex: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    eth_getLogs(ctx, INVALID_JSON, collect_error_cb, &s);
    TEST("eth_getLogs invalid JSON filter: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    eth_newFilter(ctx, INVALID_JSON, collect_error_cb, &s);
    TEST("eth_newFilter invalid JSON filter: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    eth_call(ctx, INVALID_JSON, "latest", false, collect_error_cb, &s);
    TEST("eth_call invalid tx args: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    eth_estimateGas(ctx, INVALID_JSON, "latest", false, collect_error_cb, &s);
    TEST("eth_estimateGas invalid tx args: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    eth_createAccessList(ctx, INVALID_JSON, "latest", false, collect_error_cb, &s);
    TEST("eth_createAccessList invalid tx args: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    eth_feeHistory(ctx, 4ULL, "latest", INVALID_JSON, collect_error_cb, &s);
    TEST("eth_feeHistory invalid percentiles JSON: error returned", s.called && s.status == RET_DESER_ERROR);
}

// proxyCall routes by deserializing json array of params and passing them to the
// above tested methods
static void check_proxyCall_errors(Context *ctx) {
    printf("\n proxyCall validation\n");
    CbState s;

    s = (CbState){0};
    proxyCall(ctx, "eth_unknownMethod", "[]", collect_error_cb, &s);
    TEST("proxyCall unknown method: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    proxyCall(ctx, "eth_blockNumber", "!!!not json!!!", collect_error_cb, &s);
    TEST("proxyCall invalid JSON params: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    proxyCall(ctx, "eth_getBalance", "[]", collect_error_cb, &s);
    TEST("proxyCall eth_getBalance 0 params: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    proxyCall(ctx, "eth_getBalance",
             "[\"0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC\"]",
             collect_error_cb, &s);
    TEST("proxyCall eth_getBalance 1 param: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    proxyCall(ctx, "eth_getBalance",
             "[\"not-an-address\", \"latest\"]",
             collect_error_cb, &s);
    TEST("proxyCall eth_getBalance bad address: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    proxyCall(ctx, "eth_getStorageAt",
             "[\"0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2\", \"0x0\"]",
             collect_error_cb, &s);
    TEST("proxyCall eth_getStorageAt 2 params: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    proxyCall(ctx, "eth_getBlockByHash",
             "[\"0x56a9bb0302da44b8c0b3df540781424684c3af04d0b7a38d72842b762076a664\"]",
             collect_error_cb, &s);
    TEST("proxyCall eth_getBlockByHash 1 param: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    proxyCall(ctx, "eth_getBlockByHash", "[\"not-a-hash\", false]", collect_error_cb, &s);
    TEST("proxyCall eth_getBlockByHash bad hash: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    proxyCall(ctx, "eth_getTransactionByHash", "[\"not-a-hash\"]", collect_error_cb, &s);
    TEST("proxyCall eth_getTransactionByHash bad hash: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    proxyCall(ctx, "eth_call",
             "[{\"to\":\"0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2\"}, \"latest\"]",
             collect_error_cb, &s);
    TEST("proxyCall eth_call 2 params: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    proxyCall(ctx, "eth_feeHistory", "[4, \"latest\"]", collect_error_cb, &s);
    TEST("proxyCall eth_feeHistory 2 params: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    proxyCall(ctx, "eth_getLogs", "[]", collect_error_cb, &s);
    TEST("proxyCall eth_getLogs 0 params: error returned", s.called && s.status == RET_DESER_ERROR);

    s = (CbState){0};
    proxyCall(ctx, "eth_sendRawTransaction", "[\"not-hex-bytes\"]", collect_error_cb, &s);
    TEST("proxyCall eth_sendRawTransaction non-hex: error returned", s.called && s.status == RET_DESER_ERROR);
}

static char *read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = (char *)malloc((size_t)len + 1);
    if (!buf) { fclose(f); return NULL; }
    fread(buf, 1, (size_t)len, f);
    buf[len] = '\0';
    fclose(f);
    return buf;
}

static void execution_transport(
    Context *ctx, TransportDeliveryCallback cb, void *userData)
{
    const char *name = execCtxName(userData);
    fprintf(stdout, "  [exec] %s  params=%s\n", name, execCtxParams(userData));

    const char *file = NULL;
    if (strcmp(name, "eth_getBlockByNumber") == 0 ||
        strcmp(name, "eth_getBlockByHash")   == 0)
        file = "nimbus_verified_proxy/tests/data/block_0x17a2d23.json";

    if (file) {
        char *data = read_file(file);
        if (data) {
            cb(RET_SUCCESS, data, userData);
            free(data);
            return;
        }
    }

    cb(RET_ERROR, "execution_transport: no response for method", userData);
}

static void beacon_transport(
    Context *ctx, TransportDeliveryCallback cb, void *userData)
{
    const char *endpoint = beaconCtxEndpoint(userData);
    fprintf(stdout, "  [beacon] url: %s, endpoint: %s, params: %s\n",
           beaconCtxUrl(userData), endpoint, beaconCtxParams(userData));

    const char *file = NULL;
    if (strcmp(endpoint, "getLightClientBootstrap") == 0)
        file = "nimbus_verified_proxy/tests/data/lc_bootstrap.json";
    else if (strcmp(endpoint, "getLightClientUpdatesByRange") == 0)
        file = "nimbus_verified_proxy/tests/data/lc_updates.json";
    else if (strcmp(endpoint, "getLightClientOptimisticUpdate") == 0)
        file = "nimbus_verified_proxy/tests/data/lc_optimistic.json";
    else if (strcmp(endpoint, "getLightClientFinalityUpdate") == 0)
        file = "nimbus_verified_proxy/tests/data/lc_finality.json";

    if (file) {
        char *data = read_file(file);
        if (data) {
            cb(RET_SUCCESS, data, userData);
            free(data);
            return;
        }
    }

    cb(RET_ERROR, "beacon_transport: no response for endpoint", userData);
}

static void drain(Context *ctx, int max_iters) {
    for (int i = 0; i < max_iters; i++) {
        if (processVerifProxyTasks(ctx) == RET_CANCELLED) break;
    }
}

// we run two functions by mocking the transport to verify the event loop machinery
// NOTE: this is very rudimentary because we run the processVerifProxyTasks for a
// limited number of iterations and it is difficult to calculate the exact number of
// iterations it has to be run for. If a test fails because the callback was never
// called the iterations probably need to be increased.
static void check_event_loop(Context *ctx) {
    printf("\n Event loop\n");
    CbState gas_s    = {0};
    CbState prio_s   = {0};
    CbState latest_s = {0};

    eth_gasPrice(ctx, collect_error_cb, &gas_s);
    eth_maxPriorityFeePerGas(ctx, collect_error_cb, &prio_s);
    eth_getBlockByNumber(ctx, "latest", false, collect_error_cb, &latest_s);

    drain(ctx, 2000);

    TEST("eth_gasPrice: callback fired",             gas_s.called);
    TEST("eth_maxPriorityFeePerGas: callback fired", prio_s.called);
    TEST("eth_getBlockByNumber latest: callback fired", latest_s.called);
    TEST("eth_gasPrice: RET_SUCCESS",                gas_s.status  == RET_SUCCESS);
    TEST("eth_maxPriorityFeePerGas: RET_SUCCESS",    prio_s.status == RET_SUCCESS);
    TEST("eth_getBlockByNumber latest: RET_SUCCESS", latest_s.status == RET_SUCCESS);
}

int main(void) {
    printf("=== nimbus_verified_proxy C API tests ===\n");

    NimMain();

    Context *ctx = startVerifProxy(
        (char *)TEST_CONFIG,
        execution_transport,
        beacon_transport
    );

    if (!ctx) {
        fprintf(stderr, "FATAL: startVerifProxy returned NULL\n");
        return 1;
    }

    check_deser_errors(ctx);
    check_proxyCall_errors(ctx);
    check_event_loop(ctx);

    stopVerifProxy(ctx);
    freeContext(ctx);

    printf("\n=== %d / %d passed ===\n", g_passed, g_total);
    return (g_passed == g_total) ? 0 : 1;
}
