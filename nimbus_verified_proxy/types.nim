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

  VerifiedRpcProxy* = ref object
    evm*: AsyncEvm
    proxy*: RpcProxy
    headerStore*: HeaderStore
    accountsCache*: AccountsCache
    codeCache*: CodeCache
    storageCache*: StorageCache
    chainId*: UInt256
    maxBlockWalk*: uint64

  BlockTag* = eth_api_types.RtBlockIdentifier

template rpcClient*(vp: VerifiedRpcProxy): RpcClient =
  vp.proxy.getClient()

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
    maxBlockWalk: maxBlockWalk
  )
