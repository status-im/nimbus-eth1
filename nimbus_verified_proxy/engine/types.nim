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

  # Backend API
  EthApiBackend* = object
    eth_chainId*: proc(): Future[UInt256] {.async: (raises: [CancelledError]).}
    eth_getBlockByHash*: proc(
      blkHash: Hash32, fullTransactions: bool
    ): Future[BlockObject] {.async: (raises: [CancelledError]).}
    eth_getBlockByNumber*: proc(
      blkNum: BlockTag, fullTransactions: bool
    ): Future[BlockObject] {.async: (raises: [CancelledError]).}
    eth_getProof*: proc(
      address: Address, slots: seq[UInt256], blockId: BlockTag
    ): Future[ProofResponse] {.async: (raises: [CancelledError]).}
    eth_createAccessList*: proc(
      args: TransactionArgs, blockId: BlockTag
    ): Future[AccessListResult] {.async: (raises: [CancelledError]).}
    eth_getCode*: proc(address: Address, blockId: BlockTag): Future[seq[byte]] {.
      async: (raises: [CancelledError])
    .}
    eth_getBlockReceipts*: proc(blockId: BlockTag): Future[Opt[seq[ReceiptObject]]] {.
      async: (raises: [CancelledError])
    .}
    eth_getTransactionReceipt*:
      proc(txHash: Hash32): Future[ReceiptObject] {.async: (raises: [CancelledError]).}
    eth_getTransactionByHash*: proc(txHash: Hash32): Future[TransactionObject] {.
      async: (raises: [CancelledError])
    .}
    eth_getLogs*: proc(filterOptions: FilterOptions): Future[seq[LogObject]] {.
      async: (raises: [CancelledError])
    .}

  # Frontend API
  EthApiFrontend* = object # Chain
    eth_chainId*: proc(): Future[UInt256] {.async: (raises: [ValueError]).}
    eth_blockNumber*: proc(): Future[uint64] {.async: (raises: [ValueError]).}

    # State
    eth_getBalance*: proc(address: Address, blockId: BlockTag): Future[UInt256] {.
      async: (raises: [ValueError])
    .}
    eth_getStorageAt*: proc(
      address: Address, slot: UInt256, blockId: BlockTag
    ): Future[FixedBytes[32]] {.async: (raises: [ValueError]).}
    eth_getTransactionCount*: proc(
      address: Address, blockId: BlockTag
    ): Future[Quantity] {.async: (raises: [ValueError]).}
    eth_getCode*: proc(address: Address, blockId: BlockTag): Future[seq[byte]] {.
      async: (raises: [ValueError])
    .}
    eth_getProof*: proc(
      address: Address, slots: seq[UInt256], blockId: BlockTag
    ): Future[ProofResponse] {.async: (raises: [ValueError]).}

    # Block
    eth_getBlockByHash*: proc(
      blkHash: Hash32, fullTransactions: bool
    ): Future[BlockObject] {.async: (raises: [ValueError]).}
    eth_getBlockByNumber*: proc(
      blkNum: BlockTag, fullTransactions: bool
    ): Future[BlockObject] {.async: (raises: [ValueError]).}
    eth_getUncleCountByBlockHash*:
      proc(blkHash: Hash32): Future[Quantity] {.async: (raises: [ValueError]).}
    eth_getUncleCountByBlockNumber*:
      proc(blkNum: BlockTag): Future[Quantity] {.async: (raises: [ValueError]).}
    eth_getBlockTransactionCountByHash*:
      proc(blkHash: Hash32): Future[Quantity] {.async: (raises: [ValueError]).}
    eth_getBlockTransactionCountByNumber*:
      proc(blkNum: BlockTag): Future[Quantity] {.async: (raises: [ValueError]).}

    # Transaction
    eth_getTransactionByBlockHashAndIndex*: proc(
      blkHash: Hash32, index: Quantity
    ): Future[TransactionObject] {.async: (raises: [ValueError]).}
    eth_getTransactionByBlockNumberAndIndex*: proc(
      blkNum: BlockTag, index: Quantity
    ): Future[TransactionObject] {.async: (raises: [ValueError]).}
    eth_getTransactionByHash*:
      proc(txHash: Hash32): Future[TransactionObject] {.async: (raises: [ValueError]).}

    # EVM
    eth_call*: proc(
      args: TransactionArgs, blockId: BlockTag, optimisticFetch: bool = true
    ): Future[seq[byte]] {.async: (raises: [CancelledError, ValueError]).}
    eth_createAccessList*: proc(
      args: TransactionArgs, blockId: BlockTag, optimisticFetch: bool = true
    ): Future[AccessListResult] {.async: (raises: [CancelledError, ValueError]).}
    eth_estimateGas*: proc(
      args: TransactionArgs, blockId: BlockTag, optimisticFetch: bool = true
    ): Future[Quantity] {.async: (raises: [CancelledError, ValueError]).}

    # Receipts
    eth_getBlockReceipts*: proc(blockId: BlockTag): Future[Opt[seq[ReceiptObject]]] {.
      async: (raises: [ValueError])
    .}
    eth_getTransactionReceipt*:
      proc(txHash: Hash32): Future[ReceiptObject] {.async: (raises: [ValueError]).}
    eth_getLogs*: proc(filterOptions: FilterOptions): Future[seq[LogObject]] {.
      async: (raises: [ValueError])
    .}
    eth_newFilter*: proc(filterOptions: FilterOptions): Future[string] {.
      async: (raises: [ValueError])
    .}
    eth_uninstallFilter*:
      proc(filterId: string): Future[bool] {.async: (raises: [ValueError]).}
    eth_getFilterLogs*:
      proc(filterId: string): Future[seq[LogObject]] {.async: (raises: [ValueError]).}
    eth_getFilterChanges*:
      proc(filterId: string): Future[seq[LogObject]] {.async: (raises: [ValueError]).}

    # Fee-based
    eth_blobBaseFee*: proc(): Future[UInt256] {.async: (raises: [ValueError]).}
    eth_gasPrice*: proc(): Future[Quantity] {.async: (raises: [ValueError]).}
    eth_maxPriorityFeePerGas*:
      proc(): Future[Quantity] {.async: (raises: [ValueError]).}

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
