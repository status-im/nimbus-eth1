# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronicles, json_rpc/rpcclient, web3/[eth_api, eth_api_types], ./portal_bridge_conf

export rpcclient

proc newRpcClientConnect*(url: JsonRpcUrl): RpcClient =
  ## Instantiate a new JSON-RPC client and try to connect. Will quit on failure.
  case url.kind
  of HttpUrl:
    let client = newRpcHttpClient()
    try:
      waitFor client.connect(url.value)
    except CatchableError as e:
      fatal "Failed to connect to JSON-RPC server", error = $e.msg, url = url.value
      quit QuitFailure
    client
  of WsUrl:
    let client = newRpcWebSocketClient()
    try:
      waitFor client.connect(url.value)
    except CatchableError as e:
      fatal "Failed to connect to JSON-RPC server", error = $e.msg, url = url.value
      quit QuitFailure
    client

proc getBlockByNumber*(
    client: RpcClient, blockTag: RtBlockIdentifier, fullTransactions: bool = true
): Future[Result[BlockObject, string]] {.async: (raises: []).} =
  let blck =
    try:
      let res = await client.eth_getBlockByNumber(blockTag, fullTransactions)
      if res.isNil:
        return err("EL failed to provide requested block")

      res
    except CatchableError as e:
      return err("EL JSON-RPC eth_getBlockByNumber failed: " & e.msg)

  return ok(blck)
