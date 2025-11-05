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
#include <unistd.h>
#include <stdbool.h>

static bool waitOver = true;

void onBlockNumber(Context *ctx, int status, char *res) {
  printf("Blocknumber: %s\n", res);
  freeResponse(res);
}

void onStart(Context *ctx, int status, char *res) {
  printf("Verified Proxy started successfully\n");
  printf("status: %d\n", status);
  printf("response: %s\n", res);
  if (status < 0) stopVerifProxy(ctx);
  freeResponse(res);
}

void onBalance(Context *ctx, int status, char *res) {
  printf("Balance: %s\n", res);
  freeResponse(res);
}

void waitIsOver(Context *ctx, int status, char *res) {
  printf("waiting finished successfully\n");
  printf("status: %d\n", status);

  eth_blockNumber(ctx, onBlockNumber);
  eth_getBalance(ctx, "0x954a86C613fd1fBaC9C7A43a071A68254C75E4AC", "latest", onBalance);
  waitOver = true;

  freeResponse(res);
}

int main() {
  NimMain();
  Context *ctx = createAsyncTaskContext(); 

  char* jsonConfig =
    "{"
    "\"eth2Network\": \"mainnet\","
    "\"trustedBlockRoot\": \"0xd9e4f5b2e7a8e50f9348a1890114ae522d3771ddfb44d8b7e7e2978c21869e91\","
    "\"backendUrl\": \"https://eth.blockrazor.xyz\","
    "\"beaconApiUrls\": \"http://testing.mainnet.beacon-api.nimbus.team,http://www.lightclientdata.org\","
    "\"logLevel\": \"FATAL\","
    "\"logStdout\": \"None\""
    "}";

  startVerifProxy(ctx, jsonConfig, onStart);

  while(true) {
    if (waitOver) {
      waitOver = false;
      nonBusySleep(ctx, 10, waitIsOver);
    }
    pollAsyncTaskEngine(ctx);
  }
  freeContext(ctx);
}
