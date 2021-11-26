# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  json_rpc/jsonmarshal,
  stew/results,
  eth/p2p/discoveryv5/[routing_table, enr, node]

export jsonmarshal, enr, routing_table

type
  NodeInfo* = object
    nodeId: string
    nodeENR: string

  RoutingTableInfo* = object
    localKey: string
    buckets: seq[seq[string]]

proc getNodeInfo*(r: RoutingTable): NodeInfo =
  let id = "0x" & r.localNode.id.toHex()
  let enr = r.localNode.record.toURI()
  return NodeInfo(nodeId: id, nodeENR: enr)

proc getRoutingTableInfo*(r: RoutingTable): RoutingTableInfo =
  var info: RoutingTableInfo
  for b in r.buckets:
    var bucket: seq[string]
    for n in b.nodes:
      bucket.add("0x" & n.id.toHex())

    info.buckets.add(bucket)

  info.localKey = "0x" & r.localNode.id.toHex()

  info

proc toNodeWithAddress*(enr: Record): Node {.raises: [Defect, ValueError].} =
  let nodeRes = newNode(enr)
  if nodeRes.isErr():
    raise newException(ValueError, $nodeRes.error)

  let node = nodeRes.get()
  if node.address.isNone():
    raise newException(ValueError, "ENR without address")
  else:
    node

proc `%`*(value: Record): JsonNode =
  newJString(value.toURI())

proc fromJson*(n: JsonNode, argName: string, result: var Record)
    {.raises: [Defect, ValueError].} =
  n.kind.expect(JString, argName)
  if not fromURI(result, n.getStr()):
    raise newException(ValueError, "Invalid ENR")

proc `%`*(value: NodeId): JsonNode =
  %("0x" & value.toHex())

proc fromJson*(n: JsonNode, argName: string, result: var NodeId)
    {.raises: [Defect, ValueError].} =
  n.kind.expect(JString, argName)

  # TODO: fromHex (and thus parse) call seems to let pass several invalid
  # UInt256.
  result = UInt256.fromHex(n.getStr())

# TODO: This one should go to nim-json-rpc but before we can do that we will
# have to update the vendor module to the current latest.
proc fromJson*(n: JsonNode, argName: string, result: var uint16)
    {.raises: [Defect, ValueError].} =
  n.kind.expect(JInt, argName)
  let asInt = n.getBiggestInt()
  if asInt < 0:
    raise newException(
      ValueError, "JSON-RPC input is an unexpected negative value")
  if asInt > BiggestInt(uint16.high()):
    raise newException(
      ValueError, "JSON-RPC input is too large for uint32")

  result = uint16(asInt)
