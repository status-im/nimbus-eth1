#include "./verifproxy.h"
#include <stdio.h>
#include <unistd.h>
#include <stdbool.h>

static bool wait = false;

void onBlockNumber(int status, char *res) {
  printf("response: %s\n", res);
  freeResponse(res);
}

void onStart(int status, char *res) {
  printf("Verified Proxy started successfully\n");
  freeResponse(res);
}

void waitIsOver(int status, char *res) {
  printf("waiting finished successfully\n");
  printf("status: %d\n", status);
  
  wait = false;

  // printf("response: %s\n", res);
  freeResponse(res);
}

void doMultipleAsyncTasks(Context *ctx) {
  eth_blockNumber(ctx, onBlockNumber);
  nonBusySleep(ctx, 4, waitIsOver);
}

int main() {
  NimMain();
  Context *ctx = createAsyncTaskContext(); 

  const char* jsonConfig =
    "{"
    "\"Eth2Network\": \"mainnet\","
    "\"TrustedBlockRoot\": \"0x6e2b0d0725949a5ce977b61646cc4353a8c789f6c2b8fc8bfc98fcfdb99b3d0\","
    "\"Web3Url\": \"https://eth.llamarpc.com\","
    "\"LogLevel\": \"info\""
    "}";
  startVerifProxy(ctx, jsonConfig, onStart);
  while(true) {
    if (!wait) {
      wait = true;
      doMultipleAsyncTasks(ctx);
    }
    pollAsyncTaskEngine(ctx);
  }
  freeContext(ctx);
}
