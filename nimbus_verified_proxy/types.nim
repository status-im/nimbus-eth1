# nimbus_verified_proxy
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  json_rpc/[rpcproxy],
  stint,
  minilru,
  ./header_store,
  ../fluffy/evm/async_evm,
  ../execution_chain/common/common

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
    com*: CommonRef
    evm*: AsyncEvm
    proxy*: RpcProxy
    headerStore*: HeaderStore
    accountsCache*: AccountsCache
    codeCache*: CodeCache
    storageCache*: StorageCache
    chainId*: UInt256

proc new*(
    T: type VerifiedRpcProxy,
    com: CommonRef,
    proxy: RpcProxy,
    headerStore: HeaderStore,
    chainId: UInt256,
): T =
  VerifiedRpcProxy(
    com: com,
    proxy: proxy,
    headerStore: headerStore,
    accountsCache: AccountsCache.init(ACCOUNTS_CACHE_SIZE),
    codeCache: CodeCache.init(CODE_CACHE_SIZE),
    storageCache: StorageCache.init(STORAGE_CACHE_SIZE),
    chainId: chainId,
  )
