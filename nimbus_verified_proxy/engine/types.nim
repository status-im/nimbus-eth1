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

  # chain methods
  ChainIdProc* = proc(): Future[UInt256] {.async: (raises: [])}
  BlockNumberProc* = proc(): Future[uint64] {.async: (raises: [])}

  # state methods
  GetBalanceProc* = proc(address: Address, blockId: BlockTag): Future[UInt256] {.async: (raises: [])}
  GetStorageProc* = proc(
    address: Address, slot: UInt256, blockId: BlockTag
  ): Future[FixedBytes[32]] {.async: (raises: [])}
  GetTransactionCountProc* =
    proc(address: Address, blockId: BlockTag): Future[Quantity] {.async: (raises: [])}
  GetCodeProc* = proc(address: Address, blockId: BlockTag): Future[seq[byte]] {.async: (raises: [])}
  GetProofProc* = proc(
    address: Address, slots: seq[UInt256], blockId: BlockTag
  ): Future[ProofResponse] {.async: (raises: [])}

  # block methods
  GetBlockByHashProc* =
    proc(blkHash: Hash32, fullTransactions: bool): Future[BlockObject] {.async: (raises: [])}
  GetBlockByNumberProc* =
    proc(blkNum: BlockTag, fullTransactions: bool): Future[BlockObject] {.async: (raises: [])}
  GetUncleCountByBlockHashProc* = proc(blkHash: Hash32): Future[Quantity] {.async: (raises: [])}
  GetUncleCountByBlockNumberProc* = proc(blkNum: BlockTag): Future[Quantity] {.async: (raises: [])}
  GetBlockTransactionCountByHashProc* =
    proc(blkHash: Hash32): Future[Quantity] {.async: (raises: [])}
  GetBlockTransactionCountByNumberProc* =
    proc(blkNum: BlockTag): Future[Quantity] {.async: (raises: [])}

  # transaction methods
  GetTransactionByBlockHashAndIndexProc* =
    proc(blkHash: Hash32, index: Quantity): Future[TransactionObject] {.async: (raises: [])}
  GetTransactionByBlockNumberAndIndexProc* =
    proc(blkNum: BlockTag, index: Quantity): Future[TransactionObject] {.async: (raises: [])}
  GetTransactionByHashProc = proc(txHash: Hash32): Future[TransactionObject] {.async: (raises: [])}

  # evm method types for frontend with extra parameter
  FrontendCallProc* = proc(
    args: TransactionArgs, blockId: BlockTag, optimisticFetch: bool = true
  ): Future[seq[byte]] {.async: (raises: [])}
  FrontendCreateAccessListProc* = proc(
    args: TransactionArgs, blockId: BlockTag, optimisticFetch: bool = true
  ): Future[AccessListResult] {.async: (raises: [])}
  FrontendEstimateGasProc* = proc(
    args: TransactionArgs, blockId: BlockTag, optimisticFetch: bool = true
  ): Future[Quantity] {.async: (raises: [])}

  # evm method types for backend (standard)
  CallProc* =
    proc(args: TransactionArgs, blockId: BlockTag): Future[seq[byte]] {.async: (raises: [])}
  CreateAccessListProc* =
    proc(args: TransactionArgs, blockId: BlockTag): Future[AccessListResult] {.async: (raises: [])}
  EstimateGasProc* =
    proc(args: TransactionArgs, blockId: BlockTag): Future[Quantity] {.async: (raises: [])}

  # receipt methods
  GetBlockReceiptsProc =
    proc(blockId: BlockTag): Future[Opt[seq[ReceiptObject]]] {.async: (raises: [])}
  GetTransactionReceiptProc = proc(txHash: Hash32): Future[ReceiptObject] {.async: (raises: [])}
  GetLogsProc = proc(filterOptions: FilterOptions): Future[seq[LogObject]] {.async: (raises: [])}
  NewFilterProc = proc(filterOptions: FilterOptions): Future[string] {.async: (raises: [])}
  UninstallFilterProc = proc(filterId: string): Future[bool] {.async: (raises: [])}
  GetFilterLogsProc = proc(filterId: string): Future[seq[LogObject]] {.async: (raises: [])}
  GetFilterChangesProc = proc(filterId: string): Future[seq[LogObject]] {.async: (raises: [])}

  # fee based methods
  BlobBaseFeeProc = proc(): Future[UInt256] {.async: (raises: [])}
  GasPriceProc = proc(): Future[Quantity] {.async: (raises: [])}
  MaxPriorityFeePerGasProc = proc(): Future[Quantity] {.async: (raises: [])}

  EthApiBackend* = object
    eth_chainId*: ChainIdProc
    eth_getBlockByHash*: GetBlockByHashProc
    eth_getBlockByNumber*: GetBlockByNumberProc
    eth_getProof*: GetProofProc
    eth_createAccessList*: CreateAccessListProc
    eth_getCode*: GetCodeProc
    eth_getBlockReceipts*: GetBlockReceiptsProc
    eth_getTransactionReceipt*: GetTransactionReceiptProc
    eth_getTransactionByHash*: GetTransactionByHashProc
    eth_getLogs*: GetLogsProc

  EthApiFrontend* = object # Chain methods
    eth_chainId*: ChainIdProc
    eth_blockNumber*: BlockNumberProc

    # State methods
    eth_getBalance*: GetBalanceProc
    eth_getStorageAt*: GetStorageProc
    eth_getTransactionCount*: GetTransactionCountProc
    eth_getCode*: GetCodeProc
    eth_getProof*: GetProofProc

    # Block methods
    eth_getBlockByHash*: GetBlockByHashProc
    eth_getBlockByNumber*: GetBlockByNumberProc
    eth_getUncleCountByBlockHash*: GetUncleCountByBlockHashProc
    eth_getUncleCountByBlockNumber*: GetUncleCountByBlockNumberProc
    eth_getBlockTransactionCountByHash*: GetBlockTransactionCountByHashProc
    eth_getBlockTransactionCountByNumber*: GetBlockTransactionCountByNumberProc

    # Transaction methods
    eth_getTransactionByBlockHashAndIndex*: GetTransactionByBlockHashAndIndexProc
    eth_getTransactionByBlockNumberAndIndex*: GetTransactionByBlockNumberAndIndexProc
    eth_getTransactionByHash*: GetTransactionByHashProc

    # EVM methods
    eth_call*: FrontendCallProc
    eth_createAccessList*: FrontendCreateAccessListProc
    eth_estimateGas*: FrontendEstimateGasProc

    # Receipt methods
    eth_getBlockReceipts*: GetBlockReceiptsProc
    eth_getTransactionReceipt*: GetTransactionReceiptProc
    eth_getLogs*: GetLogsProc
    eth_newFilter*: NewFilterProc
    eth_uninstallFilter*: UninstallFilterProc
    eth_getFilterLogs*: GetFilterLogsProc
    eth_getFilterChanges*: GetFilterChangesProc

    # Fee-based methods
    eth_blobBaseFee*: BlobBaseFeeProc
    eth_gasPrice*: GasPriceProc
    eth_maxPriorityFeePerGas*: MaxPriorityFeePerGasProc

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
