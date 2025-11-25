# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  std/tables,
  json_rpc/rpcclient,
  web3/[eth_api, eth_api_types],
  stint,
  minilru,
  ../../execution_chain/evm/async_evm,
  ./header_store

export minilru

const
  MAX_ID_TRIES* = 10
  MAX_FILTERS* = 256

type
  AccountsCacheKey* = (Root, Address)
  AccountsCache* = LruCache[AccountsCacheKey, Account]

  CodeCacheKey* = (Root, Address)
  CodeCache* = LruCache[CodeCacheKey, seq[byte]]

  StorageCacheKey* = (Root, Address, UInt256)
  StorageCache* = LruCache[StorageCacheKey, UInt256]

  BlockTag* = eth_api_types.RtBlockIdentifier

  # generic engine error
  # All EngineError's are propagated back to the application. 
  # Anything that need not be propagated must either be translated 
  # or absorbed.
  EngineError* = object of CatchableError

  # these errors are abstracted to support a simple architecture 
  # (encode -> fetch -> decode) that is adaptable for different 
  # kinds of backends. These errors help in scoring endpoints too.
  EthBackendError* = object of EngineError
  EthBackendEncodingError* = object of EthBackendError
  EthBackendFetchError* = object of EthBackendError
  EthBackendDecodingError* = object of EthBackendError

  # besides backend errors the other errors that can occur
  # There is not much use to differentiating these and are done
  # to this extent just for the sake of it.
  UnavailableDataError* = object of EngineError
  VerificationError* = object of EngineError

  # Backend API
  EthApiBackend* = object
    eth_chainId*:
      proc(): Future[UInt256] {.async: (raises: [CancelledError, EthBackendError]).}
    eth_getBlockByHash*: proc(
      blkHash: Hash32, fullTransactions: bool
    ): Future[BlockObject] {.async: (raises: [CancelledError, EthBackendError]).}
    eth_getBlockByNumber*: proc(
      blkNum: BlockTag, fullTransactions: bool
    ): Future[BlockObject] {.async: (raises: [CancelledError, EthBackendError]).}
    eth_getProof*: proc(
      address: Address, slots: seq[UInt256], blockId: BlockTag
    ): Future[ProofResponse] {.async: (raises: [CancelledError, EthBackendError]).}
    eth_createAccessList*: proc(
      args: TransactionArgs, blockId: BlockTag
    ): Future[AccessListResult] {.async: (raises: [CancelledError, EthBackendError]).}
    eth_getCode*: proc(address: Address, blockId: BlockTag): Future[seq[byte]] {.
      async: (raises: [CancelledError, EthBackendError])
    .}
    eth_getBlockReceipts*: proc(blockId: BlockTag): Future[Opt[seq[ReceiptObject]]] {.
      async: (raises: [CancelledError, EthBackendError])
    .}
    eth_getTransactionReceipt*: proc(txHash: Hash32): Future[ReceiptObject] {.
      async: (raises: [CancelledError, EthBackendError])
    .}
    eth_getTransactionByHash*: proc(txHash: Hash32): Future[TransactionObject] {.
      async: (raises: [CancelledError, EthBackendError])
    .}
    eth_getLogs*: proc(filterOptions: FilterOptions): Future[seq[LogObject]] {.
      async: (raises: [CancelledError, EthBackendError])
    .}
    eth_feeHistory*: proc(
      blockCount: Quantity, newestBlock: BlockTag, rewardPercentiles: Opt[seq[float64]]
    ): Future[FeeHistoryResult] {.async: (raises: [CancelledError, EthBackendError]).}
    eth_sendRawTransaction*: proc(txBytes: seq[byte]): Future[Hash32] {.
      async: (raises: [CancelledError, EthBackendError])
    .}

  # Frontend API
  EthApiFrontend* = object # Chain
    eth_chainId*:
      proc(): Future[UInt256] {.async: (raises: [CancelledError, EngineError]).}
    eth_blockNumber*:
      proc(): Future[uint64] {.async: (raises: [CancelledError, EngineError]).}

    # State
    eth_getBalance*: proc(address: Address, blockId: BlockTag): Future[UInt256] {.
      async: (raises: [CancelledError, EngineError])
    .}
    eth_getStorageAt*: proc(
      address: Address, slot: UInt256, blockId: BlockTag
    ): Future[FixedBytes[32]] {.async: (raises: [CancelledError, EngineError]).}
    eth_getTransactionCount*: proc(
      address: Address, blockId: BlockTag
    ): Future[Quantity] {.async: (raises: [CancelledError, EngineError]).}
    eth_getCode*: proc(address: Address, blockId: BlockTag): Future[seq[byte]] {.
      async: (raises: [CancelledError, EngineError])
    .}
    eth_getProof*: proc(
      address: Address, slots: seq[UInt256], blockId: BlockTag
    ): Future[ProofResponse] {.async: (raises: [CancelledError, EngineError]).}

    # Block
    eth_getBlockByHash*: proc(
      blkHash: Hash32, fullTransactions: bool
    ): Future[BlockObject] {.async: (raises: [CancelledError, EngineError]).}
    eth_getBlockByNumber*: proc(
      blkNum: BlockTag, fullTransactions: bool
    ): Future[BlockObject] {.async: (raises: [CancelledError, EngineError]).}
    eth_getUncleCountByBlockHash*: proc(blkHash: Hash32): Future[Quantity] {.
      async: (raises: [CancelledError, EngineError])
    .}
    eth_getUncleCountByBlockNumber*: proc(blkNum: BlockTag): Future[Quantity] {.
      async: (raises: [CancelledError, EngineError])
    .}
    eth_getBlockTransactionCountByHash*: proc(blkHash: Hash32): Future[Quantity] {.
      async: (raises: [CancelledError, EngineError])
    .}
    eth_getBlockTransactionCountByNumber*: proc(blkNum: BlockTag): Future[Quantity] {.
      async: (raises: [CancelledError, EngineError])
    .}

    # Transaction
    eth_getTransactionByBlockHashAndIndex*: proc(
      blkHash: Hash32, index: Quantity
    ): Future[TransactionObject] {.async: (raises: [CancelledError, EngineError]).}
    eth_getTransactionByBlockNumberAndIndex*: proc(
      blkNum: BlockTag, index: Quantity
    ): Future[TransactionObject] {.async: (raises: [CancelledError, EngineError]).}
    eth_getTransactionByHash*: proc(txHash: Hash32): Future[TransactionObject] {.
      async: (raises: [CancelledError, EngineError])
    .}

    # EVM
    eth_call*: proc(
      args: TransactionArgs, blockId: BlockTag, optimisticFetch: bool = true
    ): Future[seq[byte]] {.async: (raises: [CancelledError, EngineError]).}
    eth_createAccessList*: proc(
      args: TransactionArgs, blockId: BlockTag, optimisticFetch: bool = true
    ): Future[AccessListResult] {.async: (raises: [CancelledError, EngineError]).}
    eth_estimateGas*: proc(
      args: TransactionArgs, blockId: BlockTag, optimisticFetch: bool = true
    ): Future[Quantity] {.async: (raises: [CancelledError, EngineError]).}

    # Receipts
    eth_getBlockReceipts*: proc(blockId: BlockTag): Future[Opt[seq[ReceiptObject]]] {.
      async: (raises: [CancelledError, EngineError])
    .}
    eth_getTransactionReceipt*: proc(txHash: Hash32): Future[ReceiptObject] {.
      async: (raises: [CancelledError, EngineError])
    .}
    eth_getLogs*: proc(filterOptions: FilterOptions): Future[seq[LogObject]] {.
      async: (raises: [CancelledError, EngineError])
    .}
    eth_newFilter*: proc(filterOptions: FilterOptions): Future[string] {.
      async: (raises: [CancelledError, EngineError])
    .}
    eth_uninstallFilter*: proc(filterId: string): Future[bool] {.
      async: (raises: [CancelledError, EngineError])
    .}
    eth_getFilterLogs*: proc(filterId: string): Future[seq[LogObject]] {.
      async: (raises: [CancelledError, EngineError])
    .}
    eth_getFilterChanges*: proc(filterId: string): Future[seq[LogObject]] {.
      async: (raises: [CancelledError, EngineError])
    .}

    # Fee-based
    eth_blobBaseFee*:
      proc(): Future[UInt256] {.async: (raises: [CancelledError, EngineError]).}
    eth_gasPrice*:
      proc(): Future[Quantity] {.async: (raises: [CancelledError, EngineError]).}
    eth_maxPriorityFeePerGas*:
      proc(): Future[Quantity] {.async: (raises: [CancelledError, EngineError]).}
    eth_feeHistory*: proc(
      blockCount: Quantity, newestBlock: BlockTag, rewardPercentiles: Opt[seq[float64]]
    ): Future[FeeHistoryResult] {.async: (raises: [CancelledError, EngineError]).}
    eth_sendRawTransaction*: proc(txBytes: seq[byte]): Future[Hash32] {.
      async: (raises: [CancelledError, EngineError])
    .}

  FilterStoreItem* = object
    filter*: FilterOptions
    blockMarker*: Opt[Quantity]

  RpcVerificationEngine* = ref object
    evm*: AsyncEvm

    # chain stores
    headerStore*: HeaderStore
    filterStore*: Table[string, FilterStoreItem]

    # state caches
    accountsCache*: AccountsCache
    codeCache*: CodeCache
    storageCache*: StorageCache

    # interfaces
    backend*: EthApiBackend
    frontend*: EthApiFrontend

    # config items
    chainId*: UInt256
    maxBlockWalk*: uint64

  RpcVerificationEngineConf* = ref object
    chainId*: UInt256
    maxBlockWalk*: uint64
    headerStoreLen*: int
    accountCacheLen*: int
    codeCacheLen*: int
    storageCacheLen*: int
