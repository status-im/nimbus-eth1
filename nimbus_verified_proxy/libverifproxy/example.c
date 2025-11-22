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
#include <unistd.h>
#include <time.h>
#include <stdbool.h>

static int i = 0;

void onBlockNumber(Context *ctx, int status, char *res) {
  printf("Blocknumber: %s\n", res);
  i++;
  freeResponse(res);
}

void onStart(Context *ctx, int status, char *res) {
  if (status < 0){ // callback onStart is called only for errors
    printf("Problem while starting verified proxy\n");
    stopVerifProxy(ctx);
    freeContext(ctx);
    exit(EXIT_FAILURE);
  }
}

void onStorage(Context *ctx, int status, char *res) {
  printf("Storage: %s\n", res);
  i++;
  freeResponse(res);
}

void onBalance(Context *ctx, int status, char *res) {
  printf("Balance: %s\n", res);
  i++;
  freeResponse(res);
}

void onNonce(Context *ctx, int status, char *res) {
  printf("Nonce: %s\n", res);
  i++;
  freeResponse(res);
}

void onCode(Context *ctx, int status, char *res) {
  printf("Code: %s\n", res);
  i++;
  freeResponse(res);
}

void genericCallback(Context *ctx, int status, char *res) {
  printf("Status: %d\n", status);
  if (status < 0) printf("Error: %s\n", res);
  i++;
  freeResponse(res);
}

void makeCalls(Context *ctx) {
  char *BLOCK_HASH = "0xc3e9e54b01443bb4bd898e41c6d5c67616027ef8d673cb66240c66cb7dd2f3c9";
  char *TX_HASH = "0x65efb38ec10df765f11f54a415fbc4045f266e3ed4fd39c2066fccf0b54a11ac";
  char *CALL_ARGS = "{\"to\": \"0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2\",\"data\": \"0x70a08231000000000000000000000000De5ae63A348C4d63343C8E20Fb6286909418c8A4\"}";
  char *FILTER_OPTIONS = "{\"fromBlock\": \"0xed14f2\", \"toBlock\": \"0xed14f2\", \"topics\":[\"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef\"]}";

  eth_blockNumber(ctx, onBlockNumber);
  eth_getBalance(ctx, "0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC", "latest", onBalance);
  eth_getStorageAt(ctx, "0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC", "0x0", "latest", onStorage);
  eth_getTransactionCount(ctx, "0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC", "latest", onNonce);
  eth_getCode(ctx, "0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC", "latest", onCode);

  /* -------- Blocks & Uncles -------- */

  eth_getBlockByHash(ctx, BLOCK_HASH, true, genericCallback);
  eth_getBlockByNumber(ctx, "finalized", true, genericCallback);
  eth_getUncleCountByBlockNumber(ctx, "latest", genericCallback);
  eth_getUncleCountByBlockHash(ctx, BLOCK_HASH, genericCallback);

  eth_getBlockTransactionCountByNumber(ctx, "latest", genericCallback);
  eth_getBlockTransactionCountByHash(ctx, BLOCK_HASH, genericCallback);

  /* -------- Transactions -------- */
  eth_getTransactionByBlockNumberAndIndex(ctx, "latest", 0ULL, genericCallback);
  eth_getTransactionByBlockHashAndIndex(ctx, BLOCK_HASH, 0ULL, genericCallback);

  eth_getTransactionByHash(ctx, TX_HASH, genericCallback);
  eth_getTransactionReceipt(ctx, TX_HASH, genericCallback);

  eth_getBlockReceipts(ctx, "latest", genericCallback);

  /* -------- Calls, Access Lists, Gas Estimation -------- */
  eth_call(ctx, CALL_ARGS, "latest", false, genericCallback);
  eth_createAccessList(ctx, CALL_ARGS, "latest", false, genericCallback);
  eth_estimateGas(ctx, CALL_ARGS, "latest", false, genericCallback);

  /* -------- Logs & Filters -------- */
  eth_getLogs(ctx, FILTER_OPTIONS, genericCallback);
  eth_newFilter(ctx, FILTER_OPTIONS, genericCallback);
  eth_uninstallFilter(ctx, "0x1", genericCallback);
  eth_getFilterLogs(ctx, "0x1", genericCallback);
  eth_getFilterChanges(ctx, "0x1", genericCallback);
}

int main() {
  NimMain();

  char* jsonConfig =
    "{"
    "\"eth2Network\": \"mainnet\","
    "\"trustedBlockRoot\": \"0x2558d82e8b29c4151a0683e4f9d480d229d84b27b51a976f56722e014227e723\","
    "\"backendUrl\": \"https://eth.blockrazor.xyz\","
    "\"beaconApiUrls\": \"http://testing.mainnet.beacon-api.nimbus.team,http://www.lightclientdata.org\","
    "\"logLevel\": \"FATAL\","
    "\"logStdout\": \"None\""
    "}";

  Context *ctx = startVerifProxy(jsonConfig, onStart);

  clock_t start = clock();

  makeCalls(ctx);

  while(true) {
    if (clock() - start > (CLOCKS_PER_SEC) && i > 23) { //all 24 methods should return
      printf("\n\n Executing all eth api methods\n\n");
      i = 0;
      makeCalls(ctx);
      start = clock();
    }
    processVerifProxyTasks(ctx);
  }
  printf("it is here and this is the problem");
  stopVerifProxy(ctx);
  freeContext(ctx);
}
