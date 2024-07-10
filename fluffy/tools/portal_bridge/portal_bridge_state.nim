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
  ../../rpc/rpc_calls/rpc_trace_calls,
  ./[portal_bridge_conf, portal_bridge_common]

type
  StateValues = ref object
    accounts*: Table[Address, Account]
    storage*: Table[Address, Table[UInt256, UInt256]]
    code*: Table[Address, seq[byte]]

  StateDiff = ref object
    preState*: StateValues
    postState*: StateValues

  DiffType = enum
    unchanged
    create
    update
    delete

  Diff = object
    kind*: DiffType
    fromHex*: string
    toHex*: string

proc toDiff(diffJson: JsonNode): Diff =
  if diffJson.kind == JString and diffJson.getStr() == "=":
    return Diff(kind: unchanged)
  elif diffJson.kind == JObject:
    if diffJson{"+"} != nil:
      return Diff(kind: create, toHex: diffJson{"+"}.getStr())
    elif diffJson{"-"} != nil:
      return Diff(kind: delete, toHex: diffJson{"-"}.getStr())
    elif diffJson{"*"} != nil:
      let
        fromHex = diffJson{"*"}{"from"}.getStr()
        toHex = diffJson{"*"}{"to"}.getStr()
      return Diff(kind: update, fromHex: fromHex, toHex: toHex)
    else:
      doAssert false # unreachable
  else:
    doAssert false # unreachable

proc getStateDiffByBlockNumber(
    client: RpcClient, blockId: RtBlockIdentifier
): Future[Result[JsonNode, string]] {.async: (raises: []).} =
  const traceOpts = @["stateDiff"]

  try:
    let blockTraceJson = await client.trace_replayBlockTransactions(blockId, traceOpts)
    if blockTraceJson.isNil:
      return err("EL failed to provide requested state diff")

    if blockTraceJson.len() > 0:
      let stateDiffJson = blockTraceJson[0]["stateDiff"]

      for addrJson, accJson in stateDiffJson.pairs:
        echo "address: ", addrJson

        let balanceDiff = accJson["balance"]
        echo "balanceDiff: ", balanceDiff.toDiff()

        let nonceDiff = accJson["nonce"]
        echo "nonceDiff: ", nonceDiff.toDiff()

        let codeDiff = accJson["code"]
        echo "codeDiff: ", codeDiff.toDiff()

        let storageDiff = accJson["storage"]
        echo "storageDiff: ", storageDiff

        for slotKeyJson, slotValueJson in storageDiff.pairs:
          echo "slotKey: ", slotKeyJson
          echo "slotValue: ", slotValueJson.toDiff()

    ok(blockTraceJson)
  except CatchableError as e:
    return err("EL JSON-RPC trace_replayBlockTransactions failed: " & e.msg)

proc runBackfillLoop(
    #portalClient: RpcClient,
    web3Client: RpcClient,
    startBlockNumber: uint64,
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

  var currentBlockNumber = startBlockNumber
  echo "Starting from block number: ", currentBlockNumber
  while true:
    let blockObject = (
      await web3Client.getBlockByNumber(blockId(currentBlockNumber), false)
    ).valueOr:
      error "Failed to get block", error
      await sleepAsync(1.seconds)
      continue

    let stateDiff = (
      await web3Client.getStateDiffByBlockNumber(blockId(currentBlockNumber))
    ).valueOr:
      error "Failed to get state diff", error
      await sleepAsync(1.seconds)
      continue

    if currentBlockNumber mod 100000 == 0:
      echo "block number: ", blockObject.number.uint64
      echo "block stateRoot: ", blockObject.stateRoot
      echo "block uncles: ", blockObject.uncles

    inc currentBlockNumber

proc runState*(config: PortalBridgeConf) =
  let
    #portalClient = newRpcClientConnect(config.portalRpcUrl)
    web3Client = newRpcClientConnect(config.web3UrlState)

  asyncSpawn runBackfillLoop(web3Client, config.startBlockNumber)

  while true:
    poll()
