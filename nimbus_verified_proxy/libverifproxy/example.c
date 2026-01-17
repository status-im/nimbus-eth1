/**
 * nimbus_verified_proxy
 * Copyright (c) 2025 Status Research & Development GmbH
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

void onBlockNumber(Context *ctx, unsigned int reqId, int status, char *res) {
  printf("Blocknumber: %s\n", res);
  freeResponse(res);
}

void onStart(Context *ctx, unsigned int reqId, int status, char *res) {
  if (status < 0){ // callback onStart is called only for errors
    printf("Problem while starting verified proxy: %s\n", res);
    stopVerifProxy(ctx);
    freeContext(ctx);
    exit(EXIT_FAILURE);
  }
}

void onStorage(Context *ctx, unsigned int reqId, int status, char *res) {
  printf("Storage: %s\n", res);
  freeResponse(res);
}

void onBalance(Context *ctx, unsigned int reqId, int status, char *res) {
  printf("Balance: %s\n", res);
  freeResponse(res);
}

void onNonce(Context *ctx, unsigned int reqId, int status, char *res) {
  printf("Nonce: %s\n", res);
  freeResponse(res);
}

void onCode(Context *ctx, unsigned int reqId, int status, char *res) {
  printf("Code: %s\n", res);
  freeResponse(res);
}

void genericCallback(Context *ctx, unsigned int reqId, int status, char *res) {
  printf("ReqID: %d, Status: %d\n", reqId, status);
  if (status < 0) printf("Error: %s\n", res);
  freeResponse(res);
}

void onFilterCreate(Context *ctx, unsigned int reqId, int status, char *res) {
  if (status == RET_SUCCESS) {
    strncpy(filterId, &res[1], strlen(res) - 2); // remove quotes
    filterId[strlen(res) - 2] = '\0';
    filterCreated = true;
  }
  freeResponse(res);
}

void onCallComplete(Context *ctx, unsigned int reqId, int status, char *res) {
  if (status == RET_SUCCESS) {
    printf("Call Complete: %s\n", res);
  } else {
    printf("Call Error: %s\n", res);
  }
  freeResponse(res);
}

void onLogs(Context *ctx, unsigned int reqId, int status, char *res) {
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

  eth_blockNumber(ctx, 0, onBlockNumber);
  nvp_call(ctx, 0, "eth_blockNumber", "[]", onBlockNumber);

  eth_getBalance(ctx, 0, "0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC", "latest", onBalance);
  nvp_call(ctx, 0, "eth_getBalance", "[\"0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC\", \"latest\"]", onBalance);

  eth_getStorageAt(ctx, 0, "0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC", "0x0", "latest", onStorage);
  nvp_call(ctx, 0, "eth_getStorageAt", "[\"0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC\", \"0x0\", \"latest\"]", onStorage);

  eth_getTransactionCount(ctx, 0, "0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC", "latest", onNonce);
  nvp_call(ctx, 0, "eth_getTransactionCount", "[\"0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC\", \"latest\"]", onNonce);

  eth_getCode(ctx, 0, "0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC", "latest", onCode);
  nvp_call(ctx, 0, "eth_getCode", "[\"0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC\", \"latest\"]", onCode);

  /* -------- Blocks & Uncles -------- */

  eth_getBlockByHash(ctx, 10, BLOCK_HASH, false, genericCallback);
  nvp_call(ctx, 11, "eth_getBlockByHash", "[\"0xc62fa4cbdd48175b1171d8b7cede250ac1bea47ace4d19db344b922cd1e63111\", \"false\"]", genericCallback);

  eth_getBlockByNumber(ctx, 20, "latest", false, genericCallback);
  nvp_call(ctx, 21, "eth_getBlockByNumber", "[\"latest\", \"false\"]", genericCallback);

  eth_getUncleCountByBlockNumber(ctx, 30, "latest", genericCallback);
  nvp_call(ctx, 31, "eth_getUncleCountByBlockNumber", "[\"latest\"]", genericCallback);

  eth_getUncleCountByBlockHash(ctx, 40, BLOCK_HASH, genericCallback);
  nvp_call(ctx, 41, "eth_getUncleCountByBlockHash", "[\"0xc62fa4cbdd48175b1171d8b7cede250ac1bea47ace4d19db344b922cd1e63111\"]", genericCallback);

  eth_getBlockTransactionCountByNumber(ctx, 50, "latest", genericCallback);
  nvp_call(ctx, 51, "eth_getBlockTransactionCountByNumber", "[\"latest\"]", genericCallback);

  eth_getBlockTransactionCountByHash(ctx, 0, BLOCK_HASH, genericCallback);
  nvp_call(ctx, 0, "eth_getBlockTransactionCountByHash", "[\"0xc62fa4cbdd48175b1171d8b7cede250ac1bea47ace4d19db344b922cd1e63111\"]", genericCallback);

  /* -------- Transactions -------- */
  eth_getTransactionByBlockNumberAndIndex(ctx, 0, "latest", 0ULL, genericCallback);
  nvp_call(ctx, 0, "eth_getTransactionByBlockNumberAndIndex", "[\"latest\", \"0x0\"]", genericCallback);

  eth_getTransactionByBlockHashAndIndex(ctx, 0, BLOCK_HASH, 0ULL, genericCallback);
  nvp_call(ctx, 0, "eth_getTransactionByBlockHashAndIndex", "[\"0xc62fa4cbdd48175b1171d8b7cede250ac1bea47ace4d19db344b922cd1e63111\", \"0x0\"]", genericCallback);

  eth_getTransactionByHash(ctx, 0, TX_HASH, genericCallback);
  nvp_call(ctx, 0, "eth_getTransactionByHash", "[\"0xbbcd3d9bc70874c03453caa19fd91239abb0eef84dc61ca33e2110df81df330c\"]", genericCallback);

  eth_getTransactionReceipt(ctx, 0, TX_HASH, genericCallback);
  nvp_call(ctx, 0, "eth_getTransactionReceipt", "[\"0xbbcd3d9bc70874c03453caa19fd91239abb0eef84dc61ca33e2110df81df330c\"]", genericCallback);

  eth_getBlockReceipts(ctx, 0, "latest", genericCallback);
  nvp_call(ctx, 0, "eth_getBlockReceipts", "[\"latest\"]", genericCallback);

  /* -------- Calls, Access Lists, Gas Estimation -------- */
  eth_call(ctx, 111, CALL_ARGS, "latest", true, onCallComplete);
  nvp_call(ctx, 112, "eth_call", "[{\"to\": \"0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2\",\"data\": \"0x70a08231000000000000000000000000De5ae63A348C4d63343C8E20Fb6286909418c8A4\"}, \"latest\", \"true\"]", onCallComplete);

  eth_createAccessList(ctx, 222, CALL_ARGS, "latest", false, onCallComplete);
  nvp_call(ctx, 223, "eth_createAccessList", "[{\"to\": \"0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2\",\"data\": \"0x70a08231000000000000000000000000De5ae63A348C4d63343C8E20Fb6286909418c8A4\"}, \"latest\", \"false\"]", onCallComplete);

  eth_estimateGas(ctx, 333, CALL_ARGS, "latest", false, onCallComplete);
  nvp_call(ctx, 334, "eth_estimateGas", "[{\"to\": \"0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2\",\"data\": \"0x70a08231000000000000000000000000De5ae63A348C4d63343C8E20Fb6286909418c8A4\"}, \"latest\", \"false\"]", onCallComplete);

  /* -------- Logs & Filters -------- */
  eth_getLogs(ctx, 444, FILTER_OPTIONS, onLogs);
  nvp_call(ctx, 445, "eth_getLogs", "[{\"fromBlock\": \"latest\", \"toBlock\": \"latest\", \"topics\":[\"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef\"]}]", onLogs);
  if (filterCreated) {
    eth_getFilterLogs(ctx, 0, filterId, onLogs);
    eth_getFilterChanges(ctx, 0, filterId, onLogs);
  } else {
    nvp_call(ctx, 555, "eth_newFilter", "[{\"fromBlock\": \"latest\", \"toBlock\": \"latest\", \"topics\":[\"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef\"]}]", onFilterCreate);
    eth_newFilter(ctx, 0, FILTER_OPTIONS, onFilterCreate);
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

  Context *ctx = startVerifProxy(jsonConfig, onStart);

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
