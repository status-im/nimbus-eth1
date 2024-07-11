# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronicles,
  stew/byteutils,
  stint,
  web3/[eth_api, eth_api_types],
  results,
  eth/common/[eth_types, eth_types_rlp],
  ../../rpc/rpc_calls/rpc_trace_calls,
  ./[portal_bridge_conf, portal_bridge_common]

type
  DiffType = enum
    unchanged
    create
    update
    delete

  Code = seq[byte]
  StateValue = UInt256 | AccountNonce | Code

  StateValueDiff[StateValue] = object
    kind: DiffType
    prior: StateValue
    updated: StateValue

  StateDiffRef = ref object
    balances*: Table[EthAddress, StateValueDiff[UInt256]]
    nonces*: Table[EthAddress, StateValueDiff[AccountNonce]]
    storage*: Table[EthAddress, Table[UInt256, StateValueDiff[UInt256]]]
    code*: Table[EthAddress, StateValueDiff[Code]]

proc toStateValue(T: type UInt256, hex: string): T {.raises: [CatchableError].} =
  UInt256.fromHex(hex)

proc toStateValue(T: type AccountNonce, hex: string): T {.raises: [CatchableError].} =
  UInt256.fromHex(hex).truncate(uint64)

proc toStateValue(T: type Code, hex: string): T {.raises: [CatchableError].} =
  hexToSeqByte(hex)

proc toStateValueDiff(
    diffJson: JsonNode, T: type StateValue
): StateValueDiff[T] {.raises: [CatchableError].} =
  if diffJson.kind == JString and diffJson.getStr() == "=":
    return StateValueDiff[T](kind: unchanged)
  elif diffJson.kind == JObject:
    if diffJson{"+"} != nil:
      return
        StateValueDiff[T](kind: create, updated: T.toStateValue(diffJson{"+"}.getStr()))
    elif diffJson{"-"} != nil:
      return
        StateValueDiff[T](kind: delete, prior: T.toStateValue(diffJson{"-"}.getStr()))
    elif diffJson{"*"} != nil:
      return StateValueDiff[T](
        kind: update,
        prior: T.toStateValue(diffJson{"*"}{"from"}.getStr()),
        updated: T.toStateValue(diffJson{"*"}{"to"}.getStr()),
      )
    else:
      doAssert false # unreachable
  else:
    doAssert false # unreachable

proc toStateDiff(blockTraceJson: JsonNode): StateDiffRef {.raises: [CatchableError].} =
  if blockTraceJson.len() == 0:
    return nil # no state diff

  let
    stateDiffJson = blockTraceJson[0]["stateDiff"]
    stateDiff = StateDiffRef()

  for addrJson, accJson in stateDiffJson.pairs:
    let address = EthAddress.fromHex(addrJson)

    stateDiff.balances[address] = toStateValueDiff(accJson["balance"], UInt256)
    stateDiff.nonces[address] = toStateValueDiff(accJson["nonce"], AccountNonce)
    stateDiff.code[address] = toStateValueDiff(accJson["code"], Code)

    let storageDiff = accJson["storage"]
    var accountStorage: Table[UInt256, StateValueDiff[UInt256]]

    for slotKeyJson, slotValueJson in storageDiff.pairs:
      let slotKey = UInt256.fromHex(addrJson)
      accountStorage[slotKey] = toStateValueDiff(slotValueJson, UInt256)

    stateDiff.storage[address] = accountStorage

  stateDiff

proc getStateDiffByBlockNumber(
    client: RpcClient, blockId: RtBlockIdentifier
): Future[Result[StateDiffRef, string]] {.async: (raises: []).} =
  const traceOpts = @["stateDiff"]

  try:
    let blockTraceJson = await client.trace_replayBlockTransactions(blockId, traceOpts)
    if blockTraceJson.isNil:
      return err("EL failed to provide requested state diff")
    ok(blockTraceJson.toStateDiff())
  except CatchableError as e:
    return err("EL JSON-RPC trace_replayBlockTransactions failed: " & e.msg)

proc runBackfillLoop(
    #portalClient: RpcClient,
    web3Client: RpcClient,
    startBlockNumber: uint64,
) {.async: (raises: [CancelledError]).} =
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

    if not stateDiff.isNil():
      echo stateDiff.balances
      echo stateDiff.nonces
      echo stateDiff.storage
      echo stateDiff.code

    if currentBlockNumber mod 1000 == 0:
      echo "block number: ", blockObject.number.uint64
      echo "block stateRoot: ", blockObject.stateRoot
      echo "block uncles: ", blockObject.uncles

    inc currentBlockNumber

proc runState*(config: PortalBridgeConf) =
  let
    #portalClient = newRpcClientConnect(config.portalRpcUrl)
    web3Client = newRpcClientConnect(config.web3UrlState)

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

  if config.backfillState:
    asyncSpawn runBackfillLoop(web3Client, config.startBlockNumber)

  while true:
    poll()
