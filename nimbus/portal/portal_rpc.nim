# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Creates the interface for any portal client with rpc endpoints to fetch interface

import
  results,
  web3,
  chronos,
  json_rpc/rpcclient,
  ../config

export
  web3

type
  PortalRpc* = object
    url*: string
    provider: RpcClient

proc init*(rpc: type PortalRpc, url: string): PortalRpc =
  let web3 = waitFor newWeb3(url)
  PortalRpc(
    url: url,
    provider: web3.provider
  )

proc isPortalRpcEnabled*(conf: NimbusConf): bool =
  conf.portalUrl.len > 0

proc getPortalRpc*(conf: NimbusConf): Opt[PortalRpc] =
  if isPortalRpcEnabled(conf):
    Opt.some(PortalRpc.init(conf.portalUrl))
  else:
    Opt.none(PortalRpc)

proc getBlockFromRpc*(rpc: PortalRpc, blockNumber: uint64): BlockObject =
  let res = waitFor rpc.provider.eth_getBlockByNumber(blockId(blockNumber), true)
  return res 