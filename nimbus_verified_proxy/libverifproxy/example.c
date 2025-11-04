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
  printf("response: %s\n", res);
  freeResponse(res);
}

void onStart(Context *ctx, int status, char *res) {
  printf("Verified Proxy started successfully\n");
  printf("status: %d\n", status);
  printf("response: %s\n", res);
  if (status < 0) stopVerifProxy(ctx);
  freeResponse(res);
}

void waitIsOver(Context *ctx, int status, char *res) {
  printf("waiting finished successfully\n");
  printf("status: %d\n", status);

  eth_blockNumber(ctx, onBlockNumber);
  waitOver = true;

  freeResponse(res);
}

int main() {
  NimMain();
  Context *ctx = createAsyncTaskContext(); 

  char* jsonConfig =
    "{"
    "\"eth2Network\": \"mainnet\","
    "\"trustedBlockRoot\": \"0xdd8db7bfd8c96c993a4cb78e0e6607cf1dcca3f379764388248c63d2bc40443b\","
    "\"backendUrl\": \"https://eth.llamarpc.com\","
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
