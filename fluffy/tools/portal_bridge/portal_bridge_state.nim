# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import chronos, chronicles, ../../rpc/portal_rpc_client, ./portal_bridge_conf

proc runState*(config: PortalBridgeConf) =
  let
    portalClient = newRpcHttpClient()
    # TODO: Use Web3 object?
    web3Client: RpcClient =
      case config.web3UrlState.kind
      of HttpUrl:
        newRpcHttpClient()
      of WsUrl:
        newRpcWebSocketClient()
  try:
    waitFor portalClient.connect(config.rpcAddress, Port(config.rpcPort), false)
  except CatchableError as e:
    error "Failed to connect to portal RPC", error = $e.msg

  if config.web3UrlState.kind == HttpUrl:
    try:
      waitFor (RpcHttpClient(web3Client)).connect(config.web3UrlState.url)
    except CatchableError as e:
      error "Failed to connect to web3 RPC", error = $e.msg

  # TODO:
  # Here we'd want to implement initially a loop that backfills the state
  # content. Secondly, a loop that follows the head and injects the latest
  # state changes too.
  #
  # The first step would probably be the easier one to start with, as one
  # can start from genesis state.
  # It could be implemented by using the `exp_getProofsByBlockNumber` JSON-RPC
  # method from nimbus-eth1.
  # It could also be implemented by having the whole state execution happening
  # inside the bridge, and getting the blocks from era1 files.
  notice "State bridge functionality not yet implemented"
  quit QuitSuccess
