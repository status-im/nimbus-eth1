# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  std/tables,
  json_rpc/[rpcproxy, rpcclient],
  web3/[eth_api, eth_api_types],
  stint,
  minilru,
  ./header_store,
  ../execution_chain/evm/async_evm

export minilru

const
  ACCOUNTS_CACHE_SIZE = 128
  CODE_CACHE_SIZE = 64
  STORAGE_CACHE_SIZE = 256
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

  ChainIdProc* = proc(): Future[UInt256] {.async.}
  GetBlockByHashProc* =
    proc(blkHash: Hash32, fullTransactions: bool): Future[BlockObject] {.async.}
  GetBlockByNumberProc* =
    proc(blkNum: BlockTag, fullTransactions: bool): Future[BlockObject] {.async.}
  GetProofProc* = proc(
    address: Address, slots: seq[UInt256], blockId: BlockTag
  ): Future[ProofResponse] {.async.}
  CreateAccessListProc* =
    proc(args: TransactionArgs, blockId: BlockTag): Future[AccessListResult] {.async.}
  GetCodeProc* = proc(address: Address, blockId: BlockTag): Future[seq[byte]] {.async.}
  GetBlockReceiptsProc =
    proc(blockId: BlockTag): Future[Opt[seq[ReceiptObject]]] {.async.}
  GetTransactionReceiptProc = proc(txHash: Hash32): Future[ReceiptObject] {.async.}
  GetTransactionByHashProc = proc(txHash: Hash32): Future[TransactionObject] {.async.}
  GetLogsProc = proc(filterOptions: FilterOptions): Future[seq[LogObject]] {.async.}

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

  FilterStoreItem* = object
    filter*: FilterOptions
    blockMarker*: Opt[Quantity]

  VerifiedRpcProxy* = ref object
    evm*: AsyncEvm
    proxy*: RpcProxy
    headerStore*: HeaderStore
    accountsCache*: AccountsCache
    codeCache*: CodeCache
    storageCache*: StorageCache
    rpcClient*: EthApiBackend

    # TODO: when the list grows big add a config object instead
    # config parameters
    filterStore*: Table[string, FilterStoreItem]
    chainId*: UInt256
    maxBlockWalk*: uint64

proc init*(
    T: type VerifiedRpcProxy,
    proxy: RpcProxy,
    headerStore: HeaderStore,
    chainId: UInt256,
    maxBlockWalk: uint64,
): T =
  VerifiedRpcProxy(
    proxy: proxy,
    headerStore: headerStore,
    accountsCache: AccountsCache.init(ACCOUNTS_CACHE_SIZE),
    codeCache: CodeCache.init(CODE_CACHE_SIZE),
    storageCache: StorageCache.init(STORAGE_CACHE_SIZE),
    chainId: chainId,
    maxBlockWalk: maxBlockWalk,
  )

createRpcSigsFromNim(RpcClient):
  proc eth_estimateGas(args: TransactionArgs, blockTag: BlockTag): Quantity
  proc eth_maxPriorityFeePerGas(): Quantity
