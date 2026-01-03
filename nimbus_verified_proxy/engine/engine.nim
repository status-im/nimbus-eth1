# nimbus_verified_proxy
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import ./types, ./utils, ./rpc_frontend, ./header_store, ./evm

proc init*(
    T: type RpcVerificationEngine, config: RpcVerificationEngineConf
): EngineResult[T] =
  let engine = RpcVerificationEngine(
    chainId: config.chainId,
    maxBlockWalk: config.maxBlockWalk,
    headerStore: HeaderStore.new(config.headerStoreLen),
    accountsCache: AccountsCache.init(config.accountCacheLen),
    codeCache: CodeCache.init(config.codeCacheLen),
    storageCache: StorageCache.init(config.storageCacheLen),
  )

  engine.registerDefaultFrontend()

  let networkId = ?chainIdToNetworkId(config.chainId)

  # since AsyncEvm requires a few transport methods (getStorage, getCode etc.) for initialization, we initialize the proxy first then the evm within it
  engine.evm = AsyncEvm.init(engine.toAsyncEvmStateBackend(), networkId)

  ok(engine)
