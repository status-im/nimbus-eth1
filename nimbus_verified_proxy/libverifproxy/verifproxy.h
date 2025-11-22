/**
 * nimbus_verified_proxy
<<<<<<< HEAD
 * Copyright (c) 2024-2025 Status Research & Development GmbH
=======
 * Copyright (c) 2025 Status Research & Development GmbH
>>>>>>> 68847053f (init)
 * Licensed and distributed under either of
 *   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
 *   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
 * at your option. This file may not be copied, modified, or distributed except according to those terms.
 */

#ifndef __verifproxy__
#define __verifproxy__

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef __has_attribute
#define __has_attribute(x) 0
#endif

#ifndef __has_feature
#define __has_feature(x) 0
#endif

#if __has_attribute(warn_unused_result)
#define ETH_RESULT_USE_CHECK __attribute__((warn_unused_result))
#else
#define ETH_RESULT_USE_CHECK
#endif

void NimMain(void);

typedef struct Context Context;
typedef void (*CallBackProc) (Context *ctx, int status, char *res);

ETH_RESULT_USE_CHECK Context *startVerifProxy(char* configJson, CallBackProc onStart);
void freeResponse(char *res);
void freeContext(Context *ctx);
void stopVerifProxy(Context *ctx);
void processVerifProxyTasks(Context *ctx);

// basic methods
void eth_blockNumber(Context *ctx, CallBackProc cb);

// Account based methods
void eth_getBalance(Context *ctx, char *address, char *blockTag, CallBackProc onBalance);
void eth_getStorageAt(Context *ctx, char *address, char *slot, char *blockTag, CallBackProc onStorage);
void eth_getTransactionCount(Context *ctx, char *address, char *blockTag, CallBackProc onNonce);
void eth_getCode(Context *ctx, char *address, char *blockTag, CallBackProc onCode);
void eth_getBlockByHash(Context *ctx, char *blockHash, bool fullTransactions, CallBackProc onBlock);
void eth_getBlockByNumber(Context *ctx, char *blockTag, bool fullTransactions, CallBackProc onBlock);

/* -------- Basic Chain Data -------- */

void eth_blockNumber(Context *ctx, CallBackProc cb);
void eth_blobBaseFee(Context *ctx, CallBackProc cb);
void eth_gasPrice(Context *ctx, CallBackProc cb);
void eth_maxPriorityFeePerGas(Context *ctx, CallBackProc cb);

/* -------- Account & Storage -------- */

void eth_getBalance(Context *ctx, char *address, char *blockTag, CallBackProc cb);
void eth_getStorageAt(Context *ctx, char *address, char *slot, char *blockTag, CallBackProc cb);
void eth_getTransactionCount(Context *ctx, char *address, char *blockTag, CallBackProc cb);
void eth_getCode(Context *ctx, char *address, char *blockTag, CallBackProc cb);

/* -------- Blocks & Uncles -------- */

void eth_getBlockByHash(Context *ctx, char *blockHash, bool fullTransactions, CallBackProc cb);
void eth_getBlockByNumber(Context *ctx, char *blockTag, bool fullTransactions, CallBackProc cb);

void eth_getUncleCountByBlockNumber(Context *ctx, char *blockTag, CallBackProc cb);
void eth_getUncleCountByBlockHash(Context *ctx, char *blockHash, CallBackProc cb);

void eth_getBlockTransactionCountByNumber(Context *ctx, char *blockTag, CallBackProc cb);
void eth_getBlockTransactionCountByHash(Context *ctx, char *blockHash, CallBackProc cb);

void eth_getBlockReceipts(Context *ctx, char *blockTag, CallBackProc cb);

/* -------- Transactions -------- */

void eth_getTransactionByBlockNumberAndIndex(
    Context *ctx,
    char *blockTag,
    unsigned long long index,
    CallBackProc cb
);

void eth_getTransactionByBlockHashAndIndex(
    Context *ctx,
    char *blockHash,
    unsigned long long index,
    CallBackProc cb
);

void eth_getTransactionByHash(Context *ctx, char *txHash, CallBackProc cb);
void eth_getTransactionReceipt(Context *ctx, char *txHash, CallBackProc cb);

/* -------- Calls, Access Lists, Gas Estimation -------- */

void eth_call(
    Context *ctx,
    char *txArgs,
    char *blockTag,
    bool optimisticStateFetch,
    CallBackProc cb
);

void eth_createAccessList(
    Context *ctx,
    char *txArgs,
    char *blockTag,
    bool optimisticStateFetch,
    CallBackProc cb
);

void eth_estimateGas(
    Context *ctx,
    char *txArgs,
    char *blockTag,
    bool optimisticStateFetch,
    CallBackProc cb
);

/* -------- Logs & Filters -------- */

void eth_getLogs(Context *ctx, char *filterOptions, CallBackProc cb);

void eth_newFilter(Context *ctx, char *filterOptions, CallBackProc cb);
void eth_uninstallFilter(Context *ctx, char *filterId, CallBackProc cb);
void eth_getFilterLogs(Context *ctx, char *filterId, CallBackProc cb);
void eth_getFilterChanges(Context *ctx, char *filterId, CallBackProc cb);

/* -------- Receipts -------- */

#ifdef __cplusplus
}
#endif

#endif /* __verifproxy__ */
