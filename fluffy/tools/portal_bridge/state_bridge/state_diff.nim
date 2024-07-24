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
  eth/common/[eth_types, eth_types_rlp],
  ../../../rpc/rpc_calls/rpc_trace_calls,
  ../portal_bridge_common

type
  DiffType* = enum
    unchanged
    create
    update
    delete

  Code = seq[byte]
  StateValue* = UInt256 | AccountNonce | Code

  StateValueDiff*[StateValue] = object
    kind*: DiffType
    before*: StateValue
    after*: StateValue

  StateDiffRef* = object
    balances*: seq[(EthAddress, StateValueDiff[UInt256])]
    nonces*: seq[(EthAddress, StateValueDiff[AccountNonce])]
    storage*: seq[(EthAddress, seq[(UInt256, StateValueDiff[UInt256])])]
    code*: seq[(EthAddress, StateValueDiff[Code])]

proc toStateValue(T: type UInt256, hex: string): T {.raises: [ValueError].} =
  UInt256.fromHex(hex)

proc toStateValue(T: type AccountNonce, hex: string): T {.raises: [ValueError].} =
  UInt256.fromHex(hex).truncate(uint64)

proc toStateValue(T: type Code, hex: string): T {.raises: [ValueError].} =
  hexToSeqByte(hex)

proc toStateValueDiff(
    diffJson: JsonNode, T: type StateValue
): StateValueDiff[T] {.raises: [ValueError].} =
  if diffJson.kind == JString and diffJson.getStr() == "=":
    return StateValueDiff[T](kind: unchanged)
  elif diffJson.kind == JObject:
    if diffJson{"+"} != nil:
      return
        StateValueDiff[T](kind: create, after: T.toStateValue(diffJson{"+"}.getStr()))
    elif diffJson{"-"} != nil:
      return
        StateValueDiff[T](kind: delete, before: T.toStateValue(diffJson{"-"}.getStr()))
    elif diffJson{"*"} != nil:
      return StateValueDiff[T](
        kind: update,
        before: T.toStateValue(diffJson{"*"}{"from"}.getStr()),
        after: T.toStateValue(diffJson{"*"}{"to"}.getStr()),
      )
    else:
      doAssert false # unreachable
  else:
    doAssert false # unreachable

proc toStateDiff(stateDiffJson: JsonNode): StateDiffRef {.raises: [ValueError].} =
  var stateDiff = StateDiffRef()

  for addrJson, accJson in stateDiffJson.pairs:
    let address = EthAddress.fromHex(addrJson)

    stateDiff.balances.add((address, toStateValueDiff(accJson["balance"], UInt256)))
    stateDiff.nonces.add((address, toStateValueDiff(accJson["nonce"], AccountNonce)))
    stateDiff.code.add((address, toStateValueDiff(accJson["code"], Code)))

    let storageDiff = accJson["storage"]
    var accountStorage: seq[(UInt256, StateValueDiff[UInt256])]

    for slotKeyJson, slotValueJson in storageDiff.pairs:
      let slotKey = UInt256.fromHex(slotKeyJson)
      accountStorage.add((slotKey, toStateValueDiff(slotValueJson, UInt256)))

    stateDiff.storage.add((address, ensureMove(accountStorage)))

  stateDiff

proc toStateDiffs(
    blockTraceJson: JsonNode
): seq[StateDiffRef] {.raises: [ValueError].} =
  var stateDiffs = newSeqOfCap[StateDiffRef](blockTraceJson.len())
  for blockTrace in blockTraceJson:
    stateDiffs.add(blockTrace["stateDiff"].toStateDiff())

  stateDiffs

proc getStateDiffsByBlockNumber*(
    client: RpcClient, blockId: BlockIdentifier
): Future[Result[seq[StateDiffRef], string]] {.async: (raises: []).} =
  const traceOpts = @["stateDiff"]

  try:
    let blockTraceJson = await client.trace_replayBlockTransactions(blockId, traceOpts)
    if blockTraceJson.isNil:
      return err("EL failed to provide requested state diff")
    ok(blockTraceJson.toStateDiffs())
  except CatchableError as e:
    return err("EL JSON-RPC trace_replayBlockTransactions failed: " & e.msg)
