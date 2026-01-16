/**
 * nimbus_verified_proxy
 * Copyright (c) 2024-2025 Status Research & Development GmbH
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

/** Opaque execution context managed on the Nim side. */
typedef struct Context Context;

#define RET_SUCCESS     0 // when the call to eth api frontend is successful
#define RET_ERROR       -1 // when the call to eth api frontend failed with an error
#define RET_CANCELLED   -2 // when the call to the eth api frontend was cancelled
#define RET_DESER_ERROR -3 // when an error occured while deserializing arguments from C to Nim

/**
 * Callback used for all asynchronous ETH API calls.
 *
 * @param ctx    Execution context passed to the original request.
 * @param reqId  Request ID
 * @param status return codes as defined above
 * @param result pointer of the JSON encoded result string (allocated by Nim - 
 *               must be freed using freeResponse)
 */
typedef void (*CallBackProc)(Context *ctx, unsigned int reqId, int status, char *result);

/**
 * Start the verification proxy with a given configuration.
 *
 * @param configJson JSON string describing the configuration for the verification proxy.
 * @param onStart    Callback invoked once the proxy has started. NOTE: The callback is invoked
 *                   only on error otherwise the proxy runs indefinitely
 * @return           Pointer to a new Context object representing the running proxy.
 *                   Must be freed using freeContext() when no longer needed.
 */
ETH_RESULT_USE_CHECK Context *startVerifProxy(char* configJson, CallBackProc onStart);

/**
 * Free the JSON encoded result returned via the callback.
 *
 * @param res   pointer to the JSON encoded result string
 */
void freeResponse(char *res);

/**
 * Free a Context object returned by startVerifProxy().
 *
 * @param ctx Pointer to the Context to be freed.
 */
void freeContext(Context *ctx);

/**
 * Stop a running verification proxy.
 *
 * @param ctx Context pointer representing the running proxy. After calling this,
 *            the context is no longer valid and must be freed using freeContext().
 */
void stopVerifProxy(Context *ctx);

/**
 * Process pending tasks for a running verification proxy.
 *
 * This function should be called periodically to allow the proxy to handle
 * queued tasks, callbacks, and events. It is non-blocking.
 *
 * @param ctx Context pointer representing the running proxy.
 */
void processVerifProxyTasks(Context *ctx);

/* ========================================================================== */
/*                               BASIC CHAIN DATA                              */
/* ========================================================================== */

/**
 * Retrieve the current blockchain head block number.
 *
 * @param ctx   Context pointer.
 * @param reqId Request ID
 * @param cb    Callback invoked with a hex block number.
 */
void eth_blockNumber(Context *ctx, unsigned int reqId, CallBackProc cb);

/**
 * Retrieve the EIP-4844 blob base fee.
 *
 * @param ctx   Context pointer.
 * @param reqId Request ID
 * @param cb    Callback invoked with a hex blob base fee.
 */
void eth_blobBaseFee(Context *ctx, unsigned int reqId, CallBackProc cb);

/**
 * Retrieve the current gas price.
 *
 * @param ctx   Context pointer.
 * @param reqId Request ID
 * @param cb    Callback invoked with a hex gas price.
 */
void eth_gasPrice(Context *ctx, unsigned int reqId, CallBackProc cb);

/**
 * Retrieve the suggested priority fee per gas.
 *
 * @param ctx   Context pointer.
 * @param reqId Request ID
 * @param cb    Callback invoked with a hex gas tip.
 */
void eth_maxPriorityFeePerGas(Context *ctx, unsigned int reqId, CallBackProc cb);


/* ========================================================================== */
/*                          ACCOUNT & STORAGE ACCESS                           */
/* ========================================================================== */

/**
 * Retrieve an account balance.
 *
 * @param ctx       Context pointer.
 * @param reqId     Request ID
 * @param address   20-byte hex Ethereum address.
 * @param blockTag  A block identifier: "latest", "pending", "earliest", or a hex
 *                  block number such as "0x10d4f".
 * @param cb        Callback with the hex balance.
 */
void eth_getBalance(Context *ctx, unsigned int reqId, char *address, char *blockTag, CallBackProc cb);

/**
 * Retrieve storage from a contract.
 *
 * @param ctx       Context pointer.
 * @param reqId     Request ID
 * @param address   20-byte hex Ethereum address.
 * @param slot      32-byte hex-encoded storage slot index.
 * @param blockTag  A block identifier: "latest", "pending", "earliest", or a hex
 *                  block number such as "0x10d4f".
 * @param cb        Callback with the 32-byte hex slot value.
 */
void eth_getStorageAt(Context *ctx, unsigned int reqId, char *address, char *slot, char *blockTag, CallBackProc cb);

/**
 * Retrieve an address's transaction count (nonce).
 *
 * @param ctx       Context pointer.
 * @param reqId     Request ID
 * @param address   20-byte hex Ethereum address.
 * @param blockTag  A block identifier: "latest", "pending", "earliest", or a hex
 *                  block number such as "0x10d4f".
 * @param cb        Callback with the hex nonce.
 */
void eth_getTransactionCount(Context *ctx, unsigned int reqId, char *address, char *blockTag, CallBackProc cb);

/**
 * Retrieve bytecode stored at an address.
 *
 * @param ctx       Context pointer.
 * @param reqId     Request ID
 * @param address   20-byte hex Ethereum address.
 * @param blockTag  A block identifier: "latest", "pending", "earliest", or a hex
 *                  block number such as "0x10d4f".
 * @param cb        Callback with hex bytecode.
 */
void eth_getCode(Context *ctx, unsigned int reqId, char *address, char *blockTag, CallBackProc cb);


/* ========================================================================== */
/*                            BLOCK & UNCLE QUERIES                            */
/* ========================================================================== */

/**
 * Retrieve a block by hash.
 *
 * @param ctx              Context pointer.
 * @param reqId            Request ID
 * @param blockHash        32-byte hex encode block hash.
 * @param fullTransactions Whether full tx objects should be included.
 * @param cb               Callback with block data.
 */
void eth_getBlockByHash(Context *ctx, unsigned int reqId, char *blockHash, bool fullTransactions, CallBackProc cb);

/**
 * Retrieve a block by number or tag.
 *
 * @param ctx              Context pointer.
 * @param reqId            Request ID
 * @param blockTag         A block identifier: "latest", "pending", "earliest", or a hex
 *                         block number such as "0x10d4f".
 * @param fullTransactions Whether full tx objects should be included.
 * @param cb               Callback with block data.
 */
void eth_getBlockByNumber(Context *ctx, unsigned int reqId, char *blockTag, bool fullTransactions, CallBackProc cb);

/**
 * Get the number of uncles in a block.
 *
 * @param ctx       Context pointer.
 * @param reqId     Request ID
 * @param blockTag  A block identifier: "latest", "pending", "earliest", or a hex
 *                  block number such as "0x10d4f".
 * @param cb        Callback with hex uncle count.
 */
void eth_getUncleCountByBlockNumber(Context *ctx, unsigned int reqId, char *blockTag, CallBackProc cb);

/**
 * Get the number of uncles in a block.
 *
 * @param ctx       Context pointer.
 * @param reqId     Request ID
 * @param blockHash 32-byte hex encode block hash.
 * @param cb        Callback with hex uncle count.
 */
void eth_getUncleCountByBlockHash(Context *ctx, unsigned int reqId, char *blockHash, CallBackProc cb);

/**
 * Get the number of transactions in a block.
 *
 * @param ctx       Context pointer.
 * @param reqId     Request ID
 * @param blockTag  A block identifier: "latest", "pending", "earliest", or a hex
 *                  block number such as "0x10d4f".
 * @param cb        Callback with hex transaction count.
 */
void eth_getBlockTransactionCountByNumber(Context *ctx, unsigned int reqId, char *blockTag, CallBackProc cb);

/**
 * Get the number of transactions in a block identified by hash.
 *
 * @param ctx       Context pointer.
 * @param reqId     Request ID
 * @param blockHash 32-byte hex encode block hash.
 * @param cb        Callback with hex transaction count.
 */
void eth_getBlockTransactionCountByHash(Context *ctx, unsigned int reqId, char *blockHash, CallBackProc cb);


/* ========================================================================== */
/*                           TRANSACTION QUERIES                               */
/* ========================================================================== */

/**
 * Retrieve a transaction in a block by index.
 *
 * @param ctx       Context pointer.
 * @param reqId     Request ID
 * @param blockTag  A block identifier: "latest", "pending", "earliest", or a hex
 *                  block number such as "0x10d4f".
 * @param index     Zero-based transaction index
 * @param cb        Callback with transaction object.
 */
void eth_getTransactionByBlockNumberAndIndex(
    Context *ctx, unsigned int reqId,
    char *blockTag,
    unsigned long long index,
    CallBackProc cb
);

/**
 * Retrieve a transaction by block hash and index.
 *
 * @param ctx       Context pointer.
 * @param reqId     Request ID
 * @param blockHash 32-byte hex encode block hash.
 * @param index     Zero-based transaction index.
 * @param cb        Callback with transaction data.
 */
void eth_getTransactionByBlockHashAndIndex(
    Context *ctx, unsigned int reqId,
    char *blockHash,
    unsigned long long index,
    CallBackProc cb
);

/**
 * Retrieve a transaction by hash.
 *
 * @param ctx     Context pointer.
 * @param reqId   Request ID
 * @param txHash  32-byte hex encoded transaction hash.
 * @param cb      Callback with transaction object.
 */
void eth_getTransactionByHash(Context *ctx, unsigned int reqId, char *txHash, CallBackProc cb);

/**
 * Retrieve a transaction receipt by hash.
 *
 * @param ctx     Context pointer.
 * @param reqId   Request ID
 * @param txHash  32-byte hex encoded transaction hash.
 * @param cb      Callback with receipt data.
 */
void eth_getTransactionReceipt(Context *ctx, unsigned int reqId, char *txHash, CallBackProc cb);


/* ========================================================================== */
/*                          CALL / GAS / ACCESS LISTS                          */
/* ========================================================================== */

/**
 * Execute an eth_call.
 *
 * @param ctx                   Context pointer.
 * @param reqId                 Request ID
 * @param txArgs                JSON encoded string containing call parameters.
 * @param blockTag              A block identifier: "latest", "pending", "earliest", or a hex
 *                              block number such as "0x10d4f".
 * @param optimisticStateFetch  Whether optimistic state fetching is allowed.
 * @param cb                    Callback with call return data.
 */
void eth_call(
    Context *ctx, unsigned int reqId,
    char *txArgs,
    char *blockTag,
    bool optimisticStateFetch,
    CallBackProc cb
);

/**
 * Generate an EIP-2930 access list.
 *
 * @param ctx                   Context pointer.
 * @param reqId                 Request ID
 * @param txArgs                JSON encoded string containing call parameters.
 * @param blockTag              A block identifier: "latest", "pending", "earliest", or a hex
 *                              block number such as "0x10d4f".
 * @param optimisticStateFetch  Whether optimistic state fetching is allowed.
 * @param cb                    Callback with access list object.
 */
void eth_createAccessList(
    Context *ctx, unsigned int reqId,
    char *txArgs,
    char *blockTag,
    bool optimisticStateFetch,
    CallBackProc cb
);

/**
 * Estimate gas for a transaction.
 *
 * @param ctx                   Context pointer.
 * @param reqId                 Request ID
 * @param txArgs                JSON encoded string containing call parameters.
 * @param blockTag              A block identifier: "latest", "pending", "earliest", or a hex
 *                              block number such as "0x10d4f".
 * @param optimisticStateFetch  Whether optimistic state fetching is allowed.
 * @param cb                    Callback with hex gas estimate.
 */
void eth_estimateGas(
    Context *ctx, unsigned int reqId,
    char *txArgs,
    char *blockTag,
    bool optimisticStateFetch,
    CallBackProc cb
);


/* ========================================================================== */
/*                               LOGS & FILTERS                                */
/* ========================================================================== */

/**
 * Retrieve logs matching a filter.
 *
 * @param ctx           Context pointer.
 * @param reqId         Request ID
 * @param filterOptions JSON encoded string specifying the log filtering rules.
 * @param cb            Callback with array of matching logs.
 */
void eth_getLogs(Context *ctx, unsigned int reqId, char *filterOptions, CallBackProc cb);

/**
 * Create a new log filter.
 *
 * @param ctx           Context pointer.
 * @param reqId         Request ID
 * @param filterOptions JSON encoded string specifying the log filtering rules.
 * @param cb            Callback with filter ID (hex string).
 */
void eth_newFilter(Context *ctx, unsigned int reqId, char *filterOptions, CallBackProc cb);

/**
 * Remove an installed filter.
 *
 * @param ctx      Context pointer.
 * @param reqId    Request ID
 * @param filterId filter ID as a hex encoded string (as returned by eth_newFilter)
 * @param cb       Callback with boolean result.
 */
void eth_uninstallFilter(Context *ctx, unsigned int reqId, char *filterId, CallBackProc cb);

/**
 * Retrieve all logs for an installed filter.
 *
 * @param ctx      Context pointer.
 * @param reqId    Request ID
 * @param filterId filter ID as a hex encoded string (as returned by eth_newFilter)
 * @param cb       Callback with log result array.
 */
void eth_getFilterLogs(Context *ctx, unsigned int reqId, char *filterId, CallBackProc cb);

/**
 * Retrieve new logs since the previous poll.
 *
 * @param ctx      Context pointer.
 * @param reqId    Request ID
 * @param filterId filter ID as a hex encoded string (as returned by eth_newFilter)
 * @param cb       Callback with an array of new logs.
 */
void eth_getFilterChanges(Context *ctx, unsigned int reqId, char *filterId, CallBackProc cb);


/* ========================================================================== */
/*                              RECEIPT QUERIES                                */
/* ========================================================================== */

/**
 * Retrieve all receipts for a block.
 *
 * @param ctx       Context pointer.
 * @param reqId     Request ID
 * @param blockTag  A block identifier: "latest", "pending", "earliest", or a hex
 *                  block number such as "0x10d4f".
 * @param cb        Callback with an array of receipts.
 */
void eth_getBlockReceipts(Context *ctx, unsigned int reqId, char *blockTag, CallBackProc cb);

/**
 * Send a signed transaction to the RPC provider to be relayed in the network.
 *
 * @param ctx       Context pointer.
 * @param reqId     Request ID
 * @param blockTag  Hex encoded signed transaction.
 * @param cb        Callback with an array of receipts.
 */
void eth_sendRawTransaction(Context *ctx, unsigned int reqId, char *txHexBytes, CallBackProc cb);

#ifdef __cplusplus
}
#endif

#endif /* __verifproxy__ */
