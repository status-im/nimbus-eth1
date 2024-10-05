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
  eth/common/base,
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

  SlotDiff* = tuple[slotKey: UInt256, slotValueDiff: StateValueDiff[UInt256]]

  AccountDiff* = object
    address*: Address
    balanceDiff*: StateValueDiff[UInt256]
    nonceDiff*: StateValueDiff[AccountNonce]
    storageDiff*: seq[SlotDiff]
    codeDiff*: StateValueDiff[Code]

  TransactionDiff* = seq[AccountDiff]

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

proc toTransactionDiff(
    stateDiffJson: JsonNode
): TransactionDiff {.raises: [ValueError].} =
  var txDiff = newSeqOfCap[AccountDiff](stateDiffJson.len())

  for addrJson, accJson in stateDiffJson:
    let storageDiffJson = accJson["storage"]
    var storageDiff = newSeqOfCap[SlotDiff](storageDiffJson.len())

    for slotKeyJson, slotValueJson in storageDiffJson:
      storageDiff.add(
        (UInt256.fromHex(slotKeyJson), toStateValueDiff(slotValueJson, UInt256))
      )

    let accountDiff = AccountDiff(
      address: Address.fromHex(addrJson),
      balanceDiff: toStateValueDiff(accJson["balance"], UInt256),
      nonceDiff: toStateValueDiff(accJson["nonce"], AccountNonce),
      storageDiff: storageDiff,
      codeDiff: toStateValueDiff(accJson["code"], Code),
    )
    txDiff.add(accountDiff)

  txDiff

proc toTransactionDiffs(
    blockTraceJson: JsonNode
): seq[TransactionDiff] {.raises: [ValueError].} =
  var txDiffs = newSeqOfCap[TransactionDiff](blockTraceJson.len())
  for blockTrace in blockTraceJson:
    txDiffs.add(blockTrace["stateDiff"].toTransactionDiff())

  txDiffs

proc getStateDiffsByBlockNumber*(
    client: RpcClient, blockId: BlockIdentifier
): Future[Result[seq[TransactionDiff], string]] {.async: (raises: []).} =
  const traceOpts = @["stateDiff"]

  try:
    let blockTraceJson = await client.trace_replayBlockTransactions(blockId, traceOpts)
    if blockTraceJson.isNil:
      return err("EL failed to provide requested state diff")
    ok(blockTraceJson.toTransactionDiffs())
  except CatchableError as e:
    return err("EL JSON-RPC trace_replayBlockTransactions failed: " & e.msg)
