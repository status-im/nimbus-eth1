/**
 * nimbus_verified_proxy
 * Copyright (c) 2024-2026 Status Research & Development GmbH
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
 * @param ctx       Execution context passed to the original request.
 * @param status    return codes as defined above
 * @param result    pointer of the JSON encoded result string (allocated by Nim - 
 *                  must be freed using freeNimAllocatedString)
 * @param userData  pointer to user data
 */
typedef void (*CallBackProc)(Context *ctx, int status, char *result, void *userData);

/**
 * Transport functions used to dispatch JSON RPC requests. (Must be implemented in the
 * application using the verified proxy library)
 *
 * @param ctx       Execution context passed to the original request.
 * @param url       URL of the endpoint to forward this request to
 * @param name      name of the RPC method
 * @param params    JSON serialized params required for the RPC method.(allocated by Nim - 
 *                  must be freed using freeNimAllocatedString)
 *                  heap by nim and must be freed by C using freeNimString
 * @param cb        Callback to be called with userData passed (see below)
 * @param userData  pointer to user data. Used to link multiple response callbacks
 *                  back to their queries. Implementation of transport functions
 *                  must appropriately relay back the userData via the transport
 *                  callback function (see above)
 */
typedef void (*TransportProc)(Context *ctx, char *url, char *name, char *params, CallBackProc cb, void *userData);

/**
 * Start the verification proxy with a given configuration.
 *
 * @param configJson JSON string describing the configuration for the verification proxy.
 * @param onStart    Callback invoked once the proxy has started. NOTE: The callback is invoked
 *                   only on error otherwise the proxy runs indefinitely
 * @param userData   pointer to user data
 * @return           Pointer to a new Context object representing the running proxy.
 *                   Must be freed using freeContext() when no longer needed.
 */
ETH_RESULT_USE_CHECK Context *startVerifProxy(char* configJson, TransportProc transport, CallBackProc onStart, void *userData);

/**
 * Free strings allocated by Nim. This currently include the JSON encoded result 
 * returned via the callback for eth_* methods and the params string passed via
 * the transport proc
 *
 * @param res   pointer to the JSON encoded result string
 */
void freeNimAllocatedString(char *res);

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
 * @param   ctx     Context pointer representing the running proxy.
 * @return  status  if the proxy was stopped this would return an error code RET_ERROR
 *                  else it would return RET_SUCCESS
 */
ETH_RESULT_USE_CHECK int processVerifProxyTasks(Context *ctx);

/**
 * call any RPC method
 *
 * @param ctx       Context pointer.
 * @param name      Name of the RPC method
 * @param params    parameters required for the RPC method
 * @param cb        Callback invoked with a hex block number.
 * @param userData  pointer to user data
 */
void nvp_call(Context *ctx, char* name, char* params, CallBackProc cb, void *userData);

/* ========================================================================== */
/*                               BASIC CHAIN DATA                              */
/* ========================================================================== */

/**
 * Retrieve the current blockchain head block number.
 *
 * @param ctx       Context pointer.
 * @param cb        Callback invoked with a hex block number.
 * @param userData  pointer to user data
 */
void eth_blockNumber(Context *ctx, CallBackProc cb, void *userData);

/**
 * Retrieve the EIP-4844 blob base fee.
 *
 * @param ctx       Context pointer.
 * @param cb        Callback invoked with a hex blob base fee.
 * @param userData  pointer to user data
 */
void eth_blobBaseFee(Context *ctx, CallBackProc cb, void *userData);

/**
 * Retrieve the current gas price.
 *
 * @param ctx       Context pointer.
 * @param cb        Callback invoked with a hex gas price.
 * @param userData  pointer to user data
 */
void eth_gasPrice(Context *ctx, CallBackProc cb, void *userData);

/**
 * Retrieve the suggested priority fee per gas.
 *
 * @param ctx       Context pointer.
 * @param cb        Callback invoked with a hex gas tip.
 * @param userData  pointer to user data
 */
void eth_maxPriorityFeePerGas(Context *ctx, CallBackProc cb, void *userData);


/* ========================================================================== */
/*                          ACCOUNT & STORAGE ACCESS                           */
/* ========================================================================== */

/**
 * Retrieve an account balance.
 *
 * @param ctx       Context pointer.
 * @param address   20-byte hex Ethereum address.
 * @param blockTag  A block identifier: "latest", "pending", "earliest", or a hex
 *                  block number such as "0x10d4f".
 * @param cb        Callback with the hex balance.
 * @param userData  pointer to user data
 */
void eth_getBalance(Context *ctx, char *address, char *blockTag, CallBackProc cb, void *userData);

/**
 * Retrieve storage from a contract.
 *
 * @param ctx       Context pointer.
 * @param address   20-byte hex Ethereum address.
 * @param slot      32-byte hex-encoded storage slot index.
 * @param blockTag  A block identifier: "latest", "pending", "earliest", or a hex
 *                  block number such as "0x10d4f".
 * @param cb        Callback with the 32-byte hex slot value.
 * @param userData  pointer to user data
 */
void eth_getStorageAt(Context *ctx, char *address, char *slot, char *blockTag, CallBackProc cb, void *userData);

/**
 * Retrieve an address's transaction count (nonce).
 *
 * @param ctx       Context pointer.
 * @param address   20-byte hex Ethereum address.
 * @param blockTag  A block identifier: "latest", "pending", "earliest", or a hex
 *                  block number such as "0x10d4f".
 * @param cb        Callback with the hex nonce.
 * @param userData  pointer to user data
 */
void eth_getTransactionCount(Context *ctx, char *address, char *blockTag, CallBackProc cb, void *userData);

/**
 * Retrieve bytecode stored at an address.
 *
 * @param ctx       Context pointer.
 * @param address   20-byte hex Ethereum address.
 * @param blockTag  A block identifier: "latest", "pending", "earliest", or a hex
 *                  block number such as "0x10d4f".
 * @param cb        Callback with hex bytecode.
 * @param userData  pointer to user data
 */
void eth_getCode(Context *ctx, char *address, char *blockTag, CallBackProc cb, void *userData);


/* ========================================================================== */
/*                            BLOCK & UNCLE QUERIES                            */
/* ========================================================================== */

/**
 * Retrieve a block by hash.
 *
 * @param ctx              Context pointer.
 * @param blockHash        32-byte hex encode block hash.
 * @param fullTransactions Whether full tx objects should be included.
 * @param cb               Callback with block data.
 * @param userData         pointer to user data
 */
void eth_getBlockByHash(Context *ctx, char *blockHash, bool fullTransactions, CallBackProc cb, void *userData);

/**
 * Retrieve a block by number or tag.
 *
 * @param ctx              Context pointer.
 * @param blockTag         A block identifier: "latest", "pending", "earliest", or a hex
 *                         block number such as "0x10d4f".
 * @param fullTransactions Whether full tx objects should be included.
 * @param cb               Callback with block data.
 * @param userData         pointer to user data
 */
void eth_getBlockByNumber(Context *ctx, char *blockTag, bool fullTransactions, CallBackProc cb, void *userData);

/**
 * Get the number of uncles in a block.
 *
 * @param ctx       Context pointer.
 * @param blockTag  A block identifier: "latest", "pending", "earliest", or a hex
 *                  block number such as "0x10d4f".
 * @param cb        Callback with hex uncle count.
 * @param userData  pointer to user data
 */
void eth_getUncleCountByBlockNumber(Context *ctx, char *blockTag, CallBackProc cb, void *userData);

/**
 * Get the number of uncles in a block.
 *
 * @param ctx       Context pointer.
 * @param blockHash 32-byte hex encode block hash.
 * @param cb        Callback with hex uncle count.
 * @param userData  pointer to user data
 */
void eth_getUncleCountByBlockHash(Context *ctx, char *blockHash, CallBackProc cb, void *userData);

/**
 * Get the number of transactions in a block.
 *
 * @param ctx       Context pointer.
 * @param blockTag  A block identifier: "latest", "pending", "earliest", or a hex
 *                  block number such as "0x10d4f".
 * @param cb        Callback with hex transaction count.
 * @param userData  pointer to user data
 */
void eth_getBlockTransactionCountByNumber(Context *ctx, char *blockTag, CallBackProc cb, void *userData);

/**
 * Get the number of transactions in a block identified by hash.
 *
 * @param ctx       Context pointer.
 * @param blockHash 32-byte hex encode block hash.
 * @param cb        Callback with hex transaction count.
 * @param userData  pointer to user data
 */
void eth_getBlockTransactionCountByHash(Context *ctx, char *blockHash, CallBackProc cb, void *userData);


/* ========================================================================== */
/*                           TRANSACTION QUERIES                               */
/* ========================================================================== */

/**
 * Retrieve a transaction in a block by index.
 *
 * @param ctx       Context pointer.
 * @param blockTag  A block identifier: "latest", "pending", "earliest", or a hex
 *                  block number such as "0x10d4f".
 * @param index     Zero-based transaction index
 * @param cb        Callback with transaction object.
 * @param userData  pointer to user data
 */
void eth_getTransactionByBlockNumberAndIndex(
    Context *ctx,
    char *blockTag,
    unsigned long long index,
    CallBackProc cb,
    void *userData
);

/**
 * Retrieve a transaction by block hash and index.
 *
 * @param ctx       Context pointer.
 * @param blockHash 32-byte hex encode block hash.
 * @param index     Zero-based transaction index.
 * @param cb        Callback with transaction data.
 * @param userData  pointer to user data
 */
void eth_getTransactionByBlockHashAndIndex(
    Context *ctx,
    char *blockHash,
    unsigned long long index,
    CallBackProc cb,
    void *userData
);

/**
 * Retrieve a transaction by hash.
 *
 * @param ctx       Context pointer.
 * @param txHash    32-byte hex encoded transaction hash.
 * @param cb        Callback with transaction object.
 * @param userData  pointer to user data
 */
void eth_getTransactionByHash(Context *ctx, char *txHash, CallBackProc cb, void *userData);

/**
 * Retrieve a transaction receipt by hash.
 *
 * @param ctx       Context pointer.
 * @param txHash    32-byte hex encoded transaction hash.
 * @param cb        Callback with receipt data.
 * @param userData  pointer to user data
 */
void eth_getTransactionReceipt(Context *ctx, char *txHash, CallBackProc cb, void *userData);


/* ========================================================================== */
/*                          CALL / GAS / ACCESS LISTS                          */
/* ========================================================================== */

/**
 * Execute an eth_call.
 *
 * @param ctx                   Context pointer.
 * @param txArgs                JSON encoded string containing call parameters.
 * @param blockTag              A block identifier: "latest", "pending", "earliest", or a hex
 *                              block number such as "0x10d4f".
 * @param optimisticStateFetch  Whether optimistic state fetching is allowed.
 * @param cb                    Callback with call return data.
 * @param userData              pointer to user data
 */
void eth_call(
    Context *ctx,
    char *txArgs,
    char *blockTag,
    bool optimisticStateFetch,
    CallBackProc cb,
    void *userData
);

/**
 * Generate an EIP-2930 access list.
 *
 * @param ctx                   Context pointer.
 * @param txArgs                JSON encoded string containing call parameters.
 * @param blockTag              A block identifier: "latest", "pending", "earliest", or a hex
 *                              block number such as "0x10d4f".
 * @param optimisticStateFetch  Whether optimistic state fetching is allowed.
 * @param cb                    Callback with access list object.
 * @param userData              pointer to user data
 */
void eth_createAccessList(
    Context *ctx,
    char *txArgs,
    char *blockTag,
    bool optimisticStateFetch,
    CallBackProc cb,
    void *userData
);

/**
 * Estimate gas for a transaction.
 *
 * @param ctx                   Context pointer.
 * @param txArgs                JSON encoded string containing call parameters.
 * @param blockTag              A block identifier: "latest", "pending", "earliest", or a hex
 *                              block number such as "0x10d4f".
 * @param optimisticStateFetch  Whether optimistic state fetching is allowed.
 * @param cb                    Callback with hex gas estimate.
 * @param userData              pointer to user data
 */
void eth_estimateGas(
    Context *ctx,
    char *txArgs,
    char *blockTag,
    bool optimisticStateFetch,
    CallBackProc cb,
    void *userData
);


/* ========================================================================== */
/*                               LOGS & FILTERS                                */
/* ========================================================================== */

/**
 * Retrieve logs matching a filter.
 *
 * @param ctx           Context pointer.
 * @param filterOptions JSON encoded string specifying the log filtering rules.
 * @param cb            Callback with array of matching logs.
 * @param userData      pointer to user data
 */
void eth_getLogs(Context *ctx, char *filterOptions, CallBackProc cb, void *userData);

/**
 * Create a new log filter.
 *
 * @param ctx           Context pointer.
 * @param filterOptions JSON encoded string specifying the log filtering rules.
 * @param cb            Callback with filter ID (hex string).
 * @param userData      pointer to user data
 */
void eth_newFilter(Context *ctx, char *filterOptions, CallBackProc cb, void *userData);

/**
 * Remove an installed filter.
 *
 * @param ctx      Context pointer.
 * @param filterId filter ID as a hex encoded string (as returned by eth_newFilter)
 * @param cb       Callback with boolean result.
 * @param userData pointer to user data
 */
void eth_uninstallFilter(Context *ctx, char *filterId, CallBackProc cb, void *userData);

/**
 * Retrieve all logs for an installed filter.
 *
 * @param ctx      Context pointer.
 * @param filterId filter ID as a hex encoded string (as returned by eth_newFilter)
 * @param cb       Callback with log result array.
 * @param userData pointer to user data
 */
void eth_getFilterLogs(Context *ctx, char *filterId, CallBackProc cb, void *userData);

/**
 * Retrieve new logs since the previous poll.
 *
 * @param ctx      Context pointer.
 * @param filterId filter ID as a hex encoded string (as returned by eth_newFilter)
 * @param cb       Callback with an array of new logs.
 * @param userData pointer to user data
 */
void eth_getFilterChanges(Context *ctx, char *filterId, CallBackProc cb, void *userData);


/* ========================================================================== */
/*                              RECEIPT QUERIES                                */
/* ========================================================================== */

/**
 * Retrieve all receipts for a block.
 *
 * @param ctx       Context pointer.
 * @param blockTag  A block identifier: "latest", "pending", "earliest", or a hex
 *                  block number such as "0x10d4f".
 * @param cb        Callback with an array of receipts.
 * @param userData  pointer to user data
 */
void eth_getBlockReceipts(Context *ctx, char *blockTag, CallBackProc cb, void *userData);

/**
 * Send a signed transaction to the RPC provider to be relayed in the network.
 *
 * @param ctx       Context pointer.
 * @param blockTag  Hex encoded signed transaction.
 * @param cb        Callback with an array of receipts.
 * @param userData  pointer to user data
 */
void eth_sendRawTransaction(Context *ctx, char *txHexBytes, CallBackProc cb, void *userData);

#ifdef __cplusplus
}
#endif

#endif /* __verifproxy__ */
