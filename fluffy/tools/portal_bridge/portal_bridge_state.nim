# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronicles,
  web3/[eth_api, eth_api_types],
  results,
  eth/common/[eth_types, eth_types_rlp],
  ./[portal_bridge_conf, portal_bridge_common]

proc runBackfillLoop(
    #portalClient: RpcClient,
    web3Client: RpcClient
) {.async: (raises: [CancelledError]).} =

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

  var currentBlockNumber: uint64 = 0

  while true:
    let blockObject = (await web3Client.getBlockByNumber(blockId(currentBlockNumber))).valueOr:
      error "Failed to get block", error
      await sleepAsync(1.seconds)
      continue

    if currentBlockNumber mod 1000 == 0:
      echo "block number: ", blockObject.number
      echo "block stateRoot: ", blockObject.stateRoot
      echo "block uncles: ", blockObject.uncles

    inc currentBlockNumber

proc runState*(config: PortalBridgeConf) =
  let
    #portalClient = newRpcClientConnect(config.portalRpcUrl)
    web3Client = newRpcClientConnect(config.web3UrlState)

  asyncSpawn runBackfillLoop(web3Client)

  while true:
    poll()
