# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  json_rpc/[rpcproxy, rpcclient],
  stint,
  minilru,
  ./header_store,
  ../portal/evm/async_evm,
  web3/eth_api_types

export minilru

const
  ACCOUNTS_CACHE_SIZE = 128
  CODE_CACHE_SIZE = 64
  STORAGE_CACHE_SIZE = 256

type
  AccountsCacheKey* = (Root, Address)
  AccountsCache* = LruCache[AccountsCacheKey, Account]

  CodeCacheKey* = (Root, Address)
  CodeCache* = LruCache[CodeCacheKey, seq[byte]]

  StorageCacheKey* = (Root, Address, UInt256)
  StorageCache* = LruCache[StorageCacheKey, UInt256]

  GetBlockByHashProc* = proc(blkHash: Hash32, fullTransactions: bool): Future[BlockObject] {.async.}
  GetBlockByNumberProc* = proc(blkHash: Hash32, fullTransactions: bool): Future[BlockObject] {.async.}
  GetProofProc* = proc(address: Address, slots: seq[UInt256], blockId: RtBlockIdentifier): Future[ProofResponse] {.async.}
  CreateAccessListProc* = proc(args: TransactionArgs, blockId: RtBlockIdentifier): Future[AccessListResult] {.async.}
  GetCodeProc* = proc(address: Address, blockId: RtBlockIdentifier): Future[seq[byte]] {.async.}

  EthApiBackend* = object
    eth_getBlockByHash*: GetBlockByHashProc
    eth_getBlockByNumber*: GetBlockByNumberProc
    eth_getProof*: GetProofProc
    eth_createAccessList*: CreateAccessListProc
    eth_getCode*: GetCodeProc

  VerifiedRpcProxy* = ref object
    evm*: AsyncEvm
    proxy*: RpcProxy
    headerStore*: HeaderStore
    accountsCache*: AccountsCache
    codeCache*: CodeCache
    storageCache*: StorageCache
    client*: EthApiBackend

    # TODO: when the list grows big add a config object instead
    # config parameters 
    chainId*: UInt256
    maxBlockWalk*: uint64

  BlockTag* = eth_api_types.RtBlockIdentifier

proc initNetworkApiBackend*(): EthApiBackend =
  EthApiBackend(
    eth_getBlockByHash: vp.proxy.getClient.eth_getBlockByHash,
    eth_getBlockByNumbe: vp.proxy.getClient.eth_getBlockByNumber,
    eth_getProof: vp.proxy.getClient.eth_getProof,
    eth_createAccessList: vp.proxy.getClient.eth_createAccessList,
    eth_getCode: vp.proxy.getClient.eth_getCode,
  )

template initMockApiBackend*(): EthApiBackend =
  initNetworkApiBackend()

proc init*(
    T: type VerifiedRpcProxy,
    proxy: RpcProxy,
    headerStore: HeaderStore,
    chainId: UInt256,
    maxBlockWalk: uint64,
    mockEthApi: bool = false,
): T =
  VerifiedRpcProxy(
    proxy: proxy,
    headerStore: headerStore,
    accountsCache: AccountsCache.init(ACCOUNTS_CACHE_SIZE),
    codeCache: CodeCache.init(CODE_CACHE_SIZE),
    storageCache: StorageCache.init(STORAGE_CACHE_SIZE),
    chainId: chainId,
    maxBlockWalk: maxBlockWalk,
    client: if mockEthApi: initMockApiBackend() else: initNetworkApiBackend(),
  )
 
