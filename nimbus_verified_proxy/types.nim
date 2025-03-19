# nimbus_verified_proxy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  json_rpc/[rpcproxy],
  web3/[primitives, eth_api_types, eth_api],
  ./header_store

type
  VerifiedRpcProxy* = ref object
    proxy*: RpcProxy
    headerStore*: HeaderStore
    chainId*: Quantity

proc new*(
    T: type VerifiedRpcProxy, proxy: RpcProxy, headerStore: HeaderStore, chainId: Quantity
): T =
  VerifiedRpcProxy(proxy: proxy, headerStore: headerStore, chainId: chainId)
