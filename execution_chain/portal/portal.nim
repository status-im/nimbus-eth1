# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  web3,
  chronos,
  chronicles,
  results,
  ../config,
  ../common,
  eth/common/[base, eth_types, keys],
  ../../portal/rpc/portal_rpc_client

logScope:
  topic = "portal"

type
  PortalRpc* = ref object
    url*: string
    provider: PortalRpcClient

  HistoryExpiryRef* = ref object
    portalEnabled*: bool
    rpc: Opt[PortalRpc]
    limit*: base.BlockNumber # blockNumber limit till portal is activated, EIP specific, TODO: not used atm?

proc init*(T: type PortalRpc, url: string): T =
  let web3 = waitFor newWeb3(url)
  T(
    url: url,
    provider: PortalRpcClient.init(web3.provider)
  )

func isPortalRpcEnabled(conf: NimbusConf): bool =
  conf.portalUrl.len > 0

proc getPortalRpc(conf: NimbusConf): Opt[PortalRpc] =
  if isPortalRpcEnabled(conf):
    Opt.some(PortalRpc.init(conf.portalUrl))
  else:
    Opt.none(PortalRpc)

proc init*(T: type HistoryExpiryRef, conf: NimbusConf, com: CommonRef): T =
  if not conf.historyExpiry:
    # history expiry haven't been activated yet
    return nil

  info "Initiating Portal with the following config",
    portalUrl = conf.portalUrl,
    historyExpiry = conf.historyExpiry,
    networkId = com.networkId,
    portalLimit = conf.historyExpiryLimit

  let
    rpc = conf.getPortalRpc()
    portalEnabled =
      if com.networkId == MainNet and rpc.isSome:
        # Portal is only available for mainnet
        true
      else:
        warn "Portal is only available for mainnet, skipping fetching data from Portal"
        false
    limit =
      if conf.historyExpiryLimit.isSome:
        conf.historyExpiryLimit.get()
      else:
        com.posBlock().get()

  T(
    portalEnabled: portalEnabled,
    rpc: rpc,
    limit: limit
  )

proc rpcProvider*(historyExpiry: HistoryExpiryRef): Result[PortalRpcClient, string] =
  if historyExpiry.portalEnabled and historyExpiry.rpc.isSome:
    ok(historyExpiry.rpc.get().provider)
  else:
    err("Portal RPC is not enabled or not available")

proc getBlockBodyByHeader*(historyExpiry: HistoryExpiryRef, header: Header): Result[BlockBody, string] =
  debug "Fetching block body from Portal"
  let rpc = historyExpiry.rpcProvider.valueOr:
    return err("Portal RPC is not available")

  (waitFor rpc.historyGetBlockBody(header)).mapErr(
    proc(e: PortalErrorResponse): string =
      debug "Portal request failed", error = $e.message
      "Portal request failed: " & $e.message
  )
