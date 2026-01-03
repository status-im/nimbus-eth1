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


  # All EngineError's are propagated back to the application. 
  # Anything that need not be propagated must either be translated 
  # or absorbed.
  EngineError* = enum
    # these errors are abstracted to support a simple architecture 
    # (encode -> fetch -> decode) that is adaptable for different 
    # kinds of backends. These errors help in scoring endpoints too.
    BackendEncodingError
    BackendFetchError
    BackendDecodingError
    BackendError # generic backend error

    FrontendError # generic frontend error

    # besides backend errors the other errors that can occur
    # There is not much use to differentiating these and are done
    # to this extent just for the sake of it.
    UnavailableDataError
    InvalidDataError
    VerificationError

  ErrorTuple = tuple[errType: EngineError, errMsg: string]
  EngineResult*[T] = Result[T, ErrorTuple]

  # Backend API
  EthApiBackend* = object
    eth_chainId*:
      proc(): Future[EngineResult[UInt256]] {.async: (raises: [CancelledError]).}
    eth_getBlockByHash*: proc(
      blkHash: Hash32, fullTransactions: bool
    ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).}
    eth_getBlockByNumber*: proc(
      blkNum: BlockTag, fullTransactions: bool
    ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).}
    eth_getProof*: proc(
      address: Address, slots: seq[UInt256], blockId: BlockTag
    ): Future[EngineResult[ProofResponse]] {.async: (raises: [CancelledError]).}
    eth_createAccessList*: proc(
      args: TransactionArgs, blockId: BlockTag
    ): Future[EngineResult[AccessListResult]] {.async: (raises: [CancelledError]).}
    eth_getCode*: proc(address: Address, blockId: BlockTag): Future[EngineResult[seq[byte]]] {.
      async: (raises: [CancelledError])
    .}
    eth_getBlockReceipts*: proc(blockId: BlockTag): Future[EngineResult[Opt[seq[ReceiptObject]]]] {.
      async: (raises: [CancelledError])
    .}
    eth_getTransactionReceipt*: proc(txHash: Hash32): Future[EngineResult[ReceiptObject]] {.
      async: (raises: [CancelledError])
    .}
    eth_getTransactionByHash*: proc(txHash: Hash32): Future[EngineResult[TransactionObject]] {.
      async: (raises: [CancelledError])
    .}
    eth_getLogs*: proc(filterOptions: FilterOptions): Future[EngineResult[seq[LogObject]]] {.
      async: (raises: [CancelledError])
    .}
    eth_feeHistory*: proc(
      blockCount: Quantity, newestBlock: BlockTag, rewardPercentiles: Opt[seq[float64]]
    ): Future[EngineResult[FeeHistoryResult]] {.async: (raises: [CancelledError]).}
    eth_sendRawTransaction*: proc(txBytes: seq[byte]): Future[EngineResult[Hash32]] {.
      async: (raises: [CancelledError])
    .}

  # Frontend API
  EthApiFrontend* = object # Chain
    eth_chainId*:
      proc(): Future[EngineResult[UInt256]] {.async: (raises: [CancelledError]).}
    eth_blockNumber*:
      proc(): Future[EngineResult[uint64]] {.async: (raises: [CancelledError]).}

    # State
    eth_getBalance*: proc(address: Address, blockId: BlockTag): Future[EngineResult[UInt256]] {.
      async: (raises: [CancelledError])
    .}
    eth_getStorageAt*: proc(
      address: Address, slot: UInt256, blockId: BlockTag
    ): Future[EngineResult[FixedBytes[32]]] {.async: (raises: [CancelledError]).}
    eth_getTransactionCount*: proc(
      address: Address, blockId: BlockTag
    ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).}
    eth_getCode*: proc(address: Address, blockId: BlockTag): Future[EngineResult[seq[byte]]] {.
      async: (raises: [CancelledError])
    .}
    eth_getProof*: proc(
      address: Address, slots: seq[UInt256], blockId: BlockTag
    ): Future[EngineResult[ProofResponse]] {.async: (raises: [CancelledError]).}

    # Block
    eth_getBlockByHash*: proc(
      blkHash: Hash32, fullTransactions: bool
    ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).}
    eth_getBlockByNumber*: proc(
      blkNum: BlockTag, fullTransactions: bool
    ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).}
    eth_getUncleCountByBlockHash*: proc(blkHash: Hash32): Future[EngineResult[Quantity]] {.
      async: (raises: [CancelledError])
    .}
    eth_getUncleCountByBlockNumber*: proc(blkNum: BlockTag): Future[EngineResult[Quantity]] {.
      async: (raises: [CancelledError])
    .}
    eth_getBlockTransactionCountByHash*: proc(blkHash: Hash32): Future[EngineResult[Quantity]] {.
      async: (raises: [CancelledError])
    .}
    eth_getBlockTransactionCountByNumber*: proc(blkNum: BlockTag): Future[EngineResult[Quantity]] {.
      async: (raises: [CancelledError])
    .}

    # Transaction
    eth_getTransactionByBlockHashAndIndex*: proc(
      blkHash: Hash32, index: Quantity
    ): Future[EngineResult[TransactionObject]] {.async: (raises: [CancelledError]).}
    eth_getTransactionByBlockNumberAndIndex*: proc(
      blkNum: BlockTag, index: Quantity
    ): Future[EngineResult[TransactionObject]] {.async: (raises: [CancelledError]).}
    eth_getTransactionByHash*: proc(txHash: Hash32): Future[EngineResult[TransactionObject]] {.
      async: (raises: [CancelledError])
    .}

    # EVM
    eth_call*: proc(
      args: TransactionArgs, blockId: BlockTag, optimisticFetch: bool = true
    ): Future[EngineResult[seq[byte]]] {.async: (raises: [CancelledError]).}
    eth_createAccessList*: proc(
      args: TransactionArgs, blockId: BlockTag, optimisticFetch: bool = true
    ): Future[EngineResult[AccessListResult]] {.async: (raises: [CancelledError]).}
    eth_estimateGas*: proc(
      args: TransactionArgs, blockId: BlockTag, optimisticFetch: bool = true
    ): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).}

    # Receipts
    eth_getBlockReceipts*: proc(blockId: BlockTag): Future[EngineResult[Opt[seq[ReceiptObject]]]] {.
      async: (raises: [CancelledError])
    .}
    eth_getTransactionReceipt*: proc(txHash: Hash32): Future[EngineResult[ReceiptObject]] {.
      async: (raises: [CancelledError])
    .}
    eth_getLogs*: proc(filterOptions: FilterOptions): Future[EngineResult[seq[LogObject]]] {.
      async: (raises: [CancelledError])
    .}
    eth_newFilter*: proc(filterOptions: FilterOptions): Future[EngineResult[string]] {.
      async: (raises: [CancelledError])
    .}
    eth_uninstallFilter*:
      proc(filterId: string): Future[EngineResult[bool]] {.async: (raises: [CancelledError]).}
    eth_getFilterLogs*:
      proc(filterId: string): Future[EngineResult[seq[LogObject]]] {.async: (raises: [CancelledError]).}
    eth_getFilterChanges*:
      proc(filterId: string): Future[EngineResult[seq[LogObject]]] {.async: (raises: [CancelledError]).}

    # Fee-based
    eth_blobBaseFee*:
      proc(): Future[EngineResult[UInt256]] {.async: (raises: [CancelledError]).}
    eth_gasPrice*:
      proc(): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).}
    eth_maxPriorityFeePerGas*:
      proc(): Future[EngineResult[Quantity]] {.async: (raises: [CancelledError]).}
    eth_feeHistory*: proc(
      blockCount: Quantity, newestBlock: BlockTag, rewardPercentiles: Opt[seq[float64]]
    ): Future[EngineResult[FeeHistoryResult]] {.async: (raises: [CancelledError]).}
    eth_sendRawTransaction*: proc(txBytes: seq[byte]): Future[EngineResult[Hash32]] {.
      async: (raises: [CancelledError])
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
