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
  freeNimAllocatedString(res);
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
  freeNimAllocatedString(res);
}

void onBalance(Context *ctx, int status, char *res, void *userData) {
  printf("Balance: %s\n", res);
  freeNimAllocatedString(res);
}

void onNonce(Context *ctx, int status, char *res, void *userData) {
  printf("Nonce: %s\n", res);
  freeNimAllocatedString(res);
}

void onCode(Context *ctx, int status, char *res, void *userData) {
  printf("Code: %s\n", res);
  freeNimAllocatedString(res);
}

void genericCallback(Context *ctx, int status, char *res, void *userData) {
  printf("ReqID: %s, Status: %d\n", (char *)userData, status);
  if (status < 0) printf("Error: %s\n", res);
  freeNimAllocatedString(res);
}

void onFilterCreate(Context *ctx, int status, char *res, void *userData) {
  if (status == RET_SUCCESS) {
    strncpy(filterId, &res[1], strlen(res) - 2); // remove quotes
    filterId[strlen(res) - 2] = '\0';
    filterCreated = true;
  }
  freeNimAllocatedString(res);
}

void onCallComplete(Context *ctx, int status, char *res, void *userData) {
  if (status == RET_SUCCESS) {
    printf("Call Complete: %s\n", res);
  } else {
    printf("Call Error: %s\n", res);
  }
  freeNimAllocatedString(res);
}

void onLogs(Context *ctx, int status, char *res, void *userData) {
  if (status == RET_SUCCESS) {
    printf("Logs fetch successful\n");
  } else {
    printf("Logs Fetch Error: %s\n", res);
  }
  freeNimAllocatedString(res);
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

const char *BLOCK = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"baseFeePerGas\":\"0xb5d68e0a3\",\"difficulty\":\"0x0\",\"extraData\":\"0x\",\"gasLimit\":\"0x1c9c380\",\"gasUsed\":\"0x1c9811e\",\"hash\":\"0x56a9bb0302da44b8c0b3df540781424684c3af04d0b7a38d72842b762076a664\",\"logsBloom\":\"0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\",\"miner\":\"0xeee27662c2b8eba3cd936a23f039f3189633e4c8\",\"mixHash\":\"0xa86c2e601b6c44eb4848f7d23d9df3113fbcac42041c49cbed5000cb4f118777\",\"nonce\":\"0x0000000000000000\",\"number\":\"0xed14f2\",\"parentHash\":\"0x55b11b918355b1ef9c5db810302ebad0bf2544255b530cdce90674d5887bb286\",\"receiptsRoot\":\"0x928073fb98ce316265ea35d95ab7e2e1206cecd85242eb841dbbcc4f568fca4b\",\"sha3Uncles\":\"0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347\",\"size\":\"0x487f\",\"stateRoot\":\"0x40c07091e16263270f3579385090fea02dd5f061ba6750228fcc082ff762fda7\",\"timestamp\":\"0x6322c973\",\"transactions\":[\"0x5ad934ee3bf2f8938d8518a3b978e81f178eaa21824ee52fef83338f786e7b59\",\"0xcf92f67b37495b4149a522da5dce665cddd1c183c79ba1e870564f77ffaabbca\",\"0x714b934c3dad0f28fbc9d0438312a3801ab863480b98be4548f36a436cf270b5\",\"0x1b86278143e06a8dcd0944d336100c8187ff1e4277ef5fd39360dd7bfcdc355b\",\"0xee199f9280622e1990c649c23907d819ab6d5a27a41dc50b625812d02af8ff0f\",\"0x810681d62880142079ffd8df6bee87cebb8fa6f8c66a836f1e4c33678cb0837d\",\"0x0235355b47d026438f0c66f09db5ed2b4462044aa632164b394cd2553fb2693e\",\"0x72c32e24f7438f3f94c9dd8c2b5a3a3121ae415a011ea26a64b8745b92b44fed\",\"0xe77cbd77faeadef0c709fc23992a37510ed06c0e9f989dc4b51400015ee434ed\",\"0xc18d08faee7bbb924b77ea5d09cac3ff3bf008f51fffd30d14e54feeb3ea61e4\",\"0xc1ef8077e3df62f078182a48b18fdb82d9aa69b523d9b6f300c2b8e1dac5ebd6\",\"0x339832e1a0bbb712f1fa25cb7fb90c7c9faca2d9520c35620bd2f1106b66efc7\",\"0x553a3a38ebf871c3ab98edacd50fa9e76a8c6c39ccd352ee4e2d1b2e3a0b969f\",\"0xc158ea664d7cfbcaf9af680b3ad7712da42ca4dc2fc3fd8d2adaf65d45c2ef6c\",\"0xa950cb26eec201768a73546683f8a9d0886ab670ef5fa7e9b81d50373b799235\",\"0x22d749c5302aae6698c54867c08399f838784522fadd53ffd024fe2f16f1052e\",\"0x7036e375dbd2c2a54e9a4041e8d8ca0623fffa7adf489d79a08914b49b3c6f1f\",\"0xf037c976a34578f42c88025cd51fcc358c510b4cec459af5462200305808a6d0\",\"0xeef5e4a5a8a557f927120bddbb55cb4ad87a082c63c3cf8581ad8a4990614c65\",\"0xd6fa4d5e7042c09e6e4fb503fbd69945a71195318bc6c8116d790eea862bdd71\",\"0x732fd0215b35bc6ba2ba370fa67133c3020c46de78c8a7b7981946cea069d874\",\"0xfc5e7ea32890c90f9f884772e7cbbbaa4976688c80133835dde5b158dae6f4a8\",\"0x5fde395a33a15f2e0b012988d047af21d8d434c3f74ccca69c3579a26cc62462\",\"0x409f265e490b0b962332b08a9bea522cbbaf3f84c812b22e5e851a330cc7d3b0\",\"0x1eef2fed2a234716f9e7546049c08f136904ad2622ae3b69ab98fcfaa52018cd\",\"0x216b67f3ad43ca4a2e64fc7a7d29643a19a4c460ad771f21a1483a23205ec45d\",\"0x61fa6bfa7d2b7d522aba1b2d9899f21f05dfca3e0498b09ff8262c921262450e\",\"0x9faff8b4d5334090550fb879260d353d81c1178c6531e8ca225a9e0a032da24a\",\"0xf0e4e1f83a2a14f076e31caf5cfa9ac26254d8cfb4fe4a5dc5bcd25ee9d428a1\",\"0xe66b3c6d173fa768ed64fa5e87b5374ff3fcf0205e5bae65ee958160c2da9fa7\",\"0x05d528b4a8a659ccea73c3946b6c049b09cbc714aefd0d26bf17739157f2fcd5\",\"0xccd037ccb864784af8932e68b1335d03ad108acac16591fe2118b3056b03b942\",\"0x1f3647004a42dca3eef8801ee35705c8f63abfec50fb2144984bcdf0e3b1741a\",\"0x8889b2ddfedc4da7b03a155ac4141978503ce7963e2f26bfc8ee94b596f43d30\",\"0x511248feb7d0e1b585b413a2adc17fa3b291ced1449031fe45ac41f602bb9b30\",\"0xa28db5a9e809a14486e747d017def59c4ef458c7b28c30e64826ec429da0d358\",\"0xe8153d04b57a972ede68a6bacbf2b5d7300764008748ba6fcee5a948da7a2c61\",\"0xf16d6eb80ec921c5ef06e1acd5a0a0f005eff6b980dd150ea079e47a61af371d\",\"0xff22311453c633e90a34514dd8c623d8fad5a8424438b86007c7db8665b4f644\",\"0x8116c74edd4607b4229babd542b13cdb99e9f7ac31d19e1be40ff43b8d740770\",\"0x44503d86e543e5574afd67df4e2ee11033a1e26573bf1abf3477a954e27e0bf6\",\"0x119c2cdcfa03938e6cd7ce3f8d99dde5062d96ec9cc25c891291784bd6d34bd1\",\"0x69a19ec0f276e8e022d6bdaebd3db544a8329a686110cea653e5590add13e34e\",\"0xb6fa2bdc210a93a55d70a68fb35fae461533262f23f70d044f21df0cb9e5c488\",\"0xadfb7d1527cc88307ef4d42d1b9728f220e746aae0db16d51b056563bb8d8e20\",\"0x35d8d742844b967047de36dbd3af43144e395be9c5afc396a281070e3de4abaa\",\"0xea1435bcea16eadc48fc64fc28a90b36e054e9a2e79109651e72ef140706bbf2\",\"0xff527682816e12a83d188b61a2e4bc5b110100c59d14560495b67e5944aab130\",\"0xcb9f25127bd802e39d8297bfbdf4e63d66387513f88beb813069550ab7f504d9\",\"0xf043430838905980a823430e5c499bd19cea82f301f6e6b92598dfb5a5d5d919\",\"0xbdb461b75bc5dbd1da7dbe3c1d3c540e5f09ebd034de12de06a2235d046bf996\",\"0x2f6dcd0baee7e9ed29d4137f66ac997caf90117da391d4b37cc8ba04a2029bb6\",\"0x4f4bec2cf3076789402b606b644f6df0f0db8c04d3ff78320177a641d94daf88\",\"0x08c87430710930718e5cc23c16c8f6f5cc5417a17f46c17c27102b9129adc1a1\",\"0xdc57e2c6414198a302c313bb79f292ec714957182dc6e6a51c739718e3378d06\",\"0x3af096859a880d9c33718eda59cb96e1504db7390d0e086c7260d91e87139eab\",\"0xf5787c239852670e313cf5eed13cf89c2ba1f5209b37c28595123f5940996338\",\"0xbbc970691625eda88a1cc18841f1fc8907f86549c93c230353d876a9718cb483\",\"0xceae7d3ab98899982623304631355510a70a1ca73fe3cb8a88216dea99e89c1d\",\"0xdd3b620b49afa578c51266b7e38da38f466150385f54a4878f3a0b794bdb926f\",\"0x1e66b94dc423d6b95c9161b4b88d8862e1d05704379386e1b5e6b7f28d62c646\",\"0xd29b41f69babd4c5c680234579467ecb3857e39e42c5b53680bc230f6832b425\",\"0x2eee61013dfe1380c8794aa110522f112ff83be81ac34e9f7995dac81b6cfced\",\"0xfe1d19700fcd7d337e8ac2f985eef5e1ef05b4802d26a1637788a2d9d3464277\",\"0xb2c83000b69838c40fc55b81970e05099bd6bb9687ae80a66b8b86f38cfe26e7\",\"0x63c06123f3faac825ff6c61a08bc551e60628d68e1479d52620ded995d0f24bc\",\"0x1d4e4495d368f7f07f62af7ca6c22215a83d872a123dfcdbb6704d8d9f3e5a92\",\"0x181372058f61ffd1e64d8c1a3732234414fdb8443a57b488b940d4eeeafe7223\",\"0x0374cabdae148b333f73a939ce24c54a613f46db615599f3a25f850493a06384\",\"0x7e6735c14377af079e148458b4e10e8a0e061c3d0e85ed53fb51680b2e373d86\",\"0xda595d3ed8d21d0af4859d4f84e17cf6436470770d084dde94d2a7cf53406bf7\",\"0x1ed7f450ac9df7e9350567679574fda3b241f7eee1997df32aa00ef4f5f5e9f2\",\"0xf25815081739f4fff71b857c2007519e9d5b742819a0209dfcf82fed66555d50\",\"0x1d88b8e30c399767d64caebb6eb53fc8ade60a9782e36383973385257c79d8c3\",\"0x000b787fdfd48ea77db5bba828b64cf04253210841921b0f478bab4d01b35448\",\"0xaa10c416b655d7810e8aa17a232e021c9a472d41d3867ffc1c5b905a4a261a01\",\"0x96362d53e53ec15a69315edcd2477a85aefbc375262865cf3e17c683d9a3c781\",\"0x0790001ef84d89fd5bd397bbf221a97b6a4ddc744ba2c3b9d0466957857b1ac5\",\"0x09b57a092d6cf3939eb4f9f59ef4121fa438b2b1a0544fce1772f42b3944502c\",\"0xf1ea27d7b3f760a68b4d57d25bb36886dbde8d76356dcdb77cf6b5e69627844d\"],\"transactionsRoot\":\"0x1ea1746468686159ce730c1cc49a886721244e5d1fa9a06d6d4196b6f013c82c\",\"uncles\":[]}}\r\n";

void send_error_transport(Context *ctx, char *name, char *params, CallBackProc cb, void *userData) {
  printf("Transport Request - Name: %s, params: %s\n", name, params);
  if(strcmp(name, "eth_getBlockByNumber")) {
    char *res = (char *)malloc(strlen(BLOCK));
    strcpy(res, BLOCK);

    // free the params string if we are done using it
    freeNimAllocatedString(params);

    cb(ctx, RET_SUCCESS, res, userData);
    free(res);
  } else {
    // free the params string if we are done using it
    freeNimAllocatedString(params);

    cb(ctx, RET_ERROR, "transport not implemented yet", userData);
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
  Context *ctx = startVerifProxy(jsonConfig, send_error_transport, onStart, userData);

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
