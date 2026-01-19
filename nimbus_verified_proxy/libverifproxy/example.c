/**
 * nimbus_verified_proxy
 * Copyright (c) 2025-2026 Status Research & Development GmbH
 * Licensed and distributed under either of
 *   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
 *   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
 * at your option. This file may not be copied, modified, or distributed except according to those terms.
 */

#include "./verifproxy.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <stdbool.h>

char filterId[67];
bool filterCreated = false;

void onBlockNumber(Context *ctx, int status, char *res, void *userData) {
  printf("Blocknumber: %s\n", res);
  freeResponse(res);
}

void onStart(Context *ctx, int status, char *res, void *userData) {
  if (status < 0){ // callback onStart is called only for errors
    printf("Problem while starting verified proxy: %s\n", res);
    stopVerifProxy(ctx);
    freeContext(ctx);
    exit(EXIT_FAILURE);
  }
}

void onStorage(Context *ctx, int status, char *res, void *userData) {
  printf("Storage: %s\n", res);
  freeResponse(res);
}

void onBalance(Context *ctx, int status, char *res, void *userData) {
  printf("Balance: %s\n", res);
  freeResponse(res);
}

void onNonce(Context *ctx, int status, char *res, void *userData) {
  printf("Nonce: %s\n", res);
  freeResponse(res);
}

void onCode(Context *ctx, int status, char *res, void *userData) {
  printf("Code: %s\n", res);
  freeResponse(res);
}

void genericCallback(Context *ctx, int status, char *res, void *userData) {
  printf("ReqID: %s, Status: %d\n", (char *)userData, status);
  if (status < 0) printf("Error: %s\n", res);
  freeResponse(res);
}

void onFilterCreate(Context *ctx, int status, char *res, void *userData) {
  if (status == RET_SUCCESS) {
    strncpy(filterId, &res[1], strlen(res) - 2); // remove quotes
    filterId[strlen(res) - 2] = '\0';
    filterCreated = true;
  }
  freeResponse(res);
}

void onCallComplete(Context *ctx, int status, char *res, void *userData) {
  if (status == RET_SUCCESS) {
    printf("Call Complete: %s\n", res);
  } else {
    printf("Call Error: %s\n", res);
  }
  freeResponse(res);
}

void onLogs(Context *ctx, int status, char *res, void *userData) {
  if (status == RET_SUCCESS) {
    printf("Logs fetch successful\n");
  } else {
    printf("Logs Fetch Error: %s\n", res);
  }
  freeResponse(res);
}

void makeCalls(Context *ctx) {
  char *BLOCK_HASH = "0xc62fa4cbdd48175b1171d8b7cede250ac1bea47ace4d19db344b922cd1e63111";
  char *TX_HASH = "0xbbcd3d9bc70874c03453caa19fd91239abb0eef84dc61ca33e2110df81df330c";
  char *CALL_ARGS = "{\"to\": \"0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2\",\"data\": \"0x70a08231000000000000000000000000De5ae63A348C4d63343C8E20Fb6286909418c8A4\"}";
  char *FILTER_OPTIONS = "{\"fromBlock\": \"latest\", \"toBlock\": \"latest\", \"topics\":[\"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef\"]}";

  eth_blockNumber(ctx, onBlockNumber, 0);
  nvp_call(ctx, "eth_blockNumber", "[]", onBlockNumber, 0);

  eth_getBalance(ctx, "0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC", "latest", onBalance, 0);
  nvp_call(ctx, "eth_getBalance", "[\"0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC\", \"latest\"]", onBalance, 0);

  eth_getStorageAt(ctx, "0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC", "0x0", "latest", onStorage, 0);
  nvp_call(ctx, "eth_getStorageAt", "[\"0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC\", \"0x0\", \"latest\"]", onStorage, 0);

  eth_getTransactionCount(ctx, "0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC", "latest", onNonce, 0);
  nvp_call(ctx, "eth_getTransactionCount", "[\"0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC\", \"latest\"]", onNonce, 0);

  eth_getCode(ctx, "0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC", "latest", onCode, 0);
  nvp_call(ctx, "eth_getCode", "[\"0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC\", \"latest\"]", onCode, 0);

  /* -------- Blocks & Uncles -------- */
  char *data = "this is an rpc request context, it could also be a pointer to a structure or primary data type";

  eth_getBlockByHash(ctx, BLOCK_HASH, false, genericCallback, data);
  nvp_call(ctx, "eth_getBlockByHash", "[\"0xc62fa4cbdd48175b1171d8b7cede250ac1bea47ace4d19db344b922cd1e63111\", \"false\"]", genericCallback, data);

  eth_getBlockByNumber(ctx, "latest", false, genericCallback, data);
  nvp_call(ctx, "eth_getBlockByNumber", "[\"latest\", \"false\"]", genericCallback, data);

  eth_getUncleCountByBlockNumber(ctx, "latest", genericCallback, data);
  nvp_call(ctx, "eth_getUncleCountByBlockNumber", "[\"latest\"]", genericCallback, data);

  eth_getUncleCountByBlockHash(ctx, BLOCK_HASH, genericCallback, data);
  nvp_call(ctx, "eth_getUncleCountByBlockHash", "[\"0xc62fa4cbdd48175b1171d8b7cede250ac1bea47ace4d19db344b922cd1e63111\"]", genericCallback, data);

  eth_getBlockTransactionCountByNumber(ctx, "latest", genericCallback, data);
  nvp_call(ctx, "eth_getBlockTransactionCountByNumber", "[\"latest\"]", genericCallback, data);

  eth_getBlockTransactionCountByHash(ctx, BLOCK_HASH, genericCallback, data);
  nvp_call(ctx, "eth_getBlockTransactionCountByHash", "[\"0xc62fa4cbdd48175b1171d8b7cede250ac1bea47ace4d19db344b922cd1e63111\"]", genericCallback, data);

  /* -------- Transactions -------- */
  eth_getTransactionByBlockNumberAndIndex(ctx, "latest", 0ULL, genericCallback, data);
  nvp_call(ctx, "eth_getTransactionByBlockNumberAndIndex", "[\"latest\", \"0x0\"]", genericCallback, data);

  eth_getTransactionByBlockHashAndIndex(ctx, BLOCK_HASH, 0ULL, genericCallback, data);
  nvp_call(ctx, "eth_getTransactionByBlockHashAndIndex", "[\"0xc62fa4cbdd48175b1171d8b7cede250ac1bea47ace4d19db344b922cd1e63111\", \"0x0\"]", genericCallback, data);

  eth_getTransactionByHash(ctx, TX_HASH, genericCallback, data);
  nvp_call(ctx, "eth_getTransactionByHash", "[\"0xbbcd3d9bc70874c03453caa19fd91239abb0eef84dc61ca33e2110df81df330c\"]", genericCallback, data);

  eth_getTransactionReceipt(ctx, TX_HASH, genericCallback, data);
  nvp_call(ctx, "eth_getTransactionReceipt", "[\"0xbbcd3d9bc70874c03453caa19fd91239abb0eef84dc61ca33e2110df81df330c\"]", genericCallback, data);

  eth_getBlockReceipts(ctx, "latest", genericCallback, data);
  nvp_call(ctx, "eth_getBlockReceipts", "[\"latest\"]", genericCallback, data);

  /* -------- Calls, Access Lists, Gas Estimation -------- */
  eth_call(ctx, CALL_ARGS, "latest", true, onCallComplete, 0);
  nvp_call(ctx, "eth_call", "[{\"to\": \"0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2\",\"data\": \"0x70a08231000000000000000000000000De5ae63A348C4d63343C8E20Fb6286909418c8A4\"}, \"latest\", \"true\"]", onCallComplete, 0);

  eth_createAccessList(ctx, CALL_ARGS, "latest", false, onCallComplete, 0);
  nvp_call(ctx, "eth_createAccessList", "[{\"to\": \"0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2\",\"data\": \"0x70a08231000000000000000000000000De5ae63A348C4d63343C8E20Fb6286909418c8A4\"}, \"latest\", \"false\"]", onCallComplete, 0);

  eth_estimateGas(ctx, CALL_ARGS, "latest", false, onCallComplete, 0);
  nvp_call(ctx, "eth_estimateGas", "[{\"to\": \"0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2\",\"data\": \"0x70a08231000000000000000000000000De5ae63A348C4d63343C8E20Fb6286909418c8A4\"}, \"latest\", \"false\"]", onCallComplete, 0);

  /* -------- Logs & Filters -------- */
  eth_getLogs(ctx, FILTER_OPTIONS, onLogs, 0);
  nvp_call(ctx, "eth_getLogs", "[{\"fromBlock\": \"latest\", \"toBlock\": \"latest\", \"topics\":[\"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef\"]}]", onLogs, 0);

  if (filterCreated) {
    eth_getFilterLogs(ctx, filterId, onLogs, 0);
    eth_getFilterChanges(ctx, filterId, onLogs, 0);
  } else {
    nvp_call(ctx, "eth_newFilter", "[{\"fromBlock\": \"latest\", \"toBlock\": \"latest\", \"topics\":[\"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef\"]}]", onFilterCreate, 0);
    eth_newFilter(ctx, FILTER_OPTIONS, onFilterCreate, 0);
  }
}

int main() {
  NimMain();

  char* jsonConfig =
    "{"
    "\"eth2Network\": \"mainnet\","
    "\"trustedBlockRoot\": \"0x2558d82e8b29c4151a0683e4f9d480d229d84b27b51a976f56722e014227e723\","
    "\"backendUrls\": \"https://eth.blockrazor.xyz\","
    "\"beaconApiUrls\": \"http://testing.mainnet.beacon-api.nimbus.team,http://www.lightclientdata.org\","
    "\"logLevel\": \"FATAL\","
    "\"logStdout\": \"None\""
    "}";

  char *userData = "verifyproxy example implementation in C";
  Context *ctx = startVerifProxy(jsonConfig, onStart, userData);

  time_t start = time(NULL);

  makeCalls(ctx);

  while(true) {
    if ((time(NULL) - start) > 12) { //all 24 methods should return
      printf("\n\n Executing all eth api methods\n\n");
      makeCalls(ctx);
      start = time(NULL);
    }
    processVerifProxyTasks(ctx);
  }
  printf("it is here and this is the problem");
  stopVerifProxy(ctx);
  freeContext(ctx);
}
