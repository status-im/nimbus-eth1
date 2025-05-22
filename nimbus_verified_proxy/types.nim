# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import stint, json_rpc/[rpcclient, rpcproxy], web3/eth_api_types, ./header_store

type
  VerifiedRpcProxy* = ref object
    proxy*: RpcProxy
    headerStore*: HeaderStore
    chainId*: UInt256

  BlockTag* = eth_api_types.RtBlockIdentifier

template rpcClient*(vp: VerifiedRpcProxy): RpcClient =
  vp.proxy.getClient()

proc init*(
    T: type VerifiedRpcProxy,
    proxy: RpcProxy,
    headerStore: HeaderStore,
    chainId: UInt256,
): T =
  VerifiedRpcProxy(proxy: proxy, headerStore: headerStore, chainId: chainId)
