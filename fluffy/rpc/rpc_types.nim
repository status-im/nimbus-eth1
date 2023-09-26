# Nimbus
# Copyright (c) 2021-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/tables,
  json_rpc/jsonmarshal,
  chronos/timer,
  stew/results,
  eth/p2p/discoveryv5/[routing_table, enr, node]

export jsonmarshal, routing_table, enr, node

type
  TraceItem* = object
    timestamp_millis*: int64
    responded_with*: seq[NodeId]

type
  NodeMetadata* = object
    enr*: Record
    ip*: string
    port*: string
    distance_to_content*: uint64 # TODO Actually it is UInt256, but it should be string representation of it
    distance_log2*: uint16

type
  StartedAt* = object
    secs_since_epoch*: int64
    nanos_since_epoch*: int64

type
  TraceContainer* = object
    received_content_from_node*: NodeId
    origin*: NodeId
    responses*: Table[string, TraceItem]
    node_metadata*: Table[string, NodeMetadata]
    started_at*: StartedAt
    target_id*: string

type
  TraceNodeInfo* = object
    content*: string
    trace*: TraceContainer

type
  NodeInfo* = object
    enr*: Record
    nodeId*: NodeId

  RoutingTableInfo* = object
    localNodeId*: NodeId
    buckets*: seq[seq[NodeId]]

func getNodeInfo*(r: RoutingTable): NodeInfo =
  NodeInfo(enr: r.localNode.record, nodeId: r.localNode.id)

func getRoutingTableInfo*(r: RoutingTable): RoutingTableInfo =
  var info: RoutingTableInfo
  for b in r.buckets:
    var bucket: seq[NodeId]
    for n in b.nodes:
      bucket.add(n.id)

    info.buckets.add(bucket)

  info.localNodeId = r.localNode.id

  info

func toNodeWithAddress*(enr: Record): Node {.raises: [ValueError].} =
  let nodeRes = newNode(enr)
  if nodeRes.isErr():
    raise newException(ValueError, $nodeRes.error)

  let node = nodeRes.get()
  if node.address.isNone():
    raise newException(ValueError, "ENR without address")
  else:
    node

func `%`*(value: Record): JsonNode =
  newJString(value.toURI())

func fromJson*(n: JsonNode, argName: string, result: var Record)
    {.raises: [ValueError].} =
  n.kind.expect(JString, argName)
  if not fromURI(result, n.getStr()):
    raise newException(ValueError, "Invalid ENR")

func `%`*(value: NodeId): JsonNode =
  %("0x" & value.toHex())

func fromJson*(n: JsonNode, argName: string, result: var NodeId)
    {.raises: [ValueError].} =
  n.kind.expect(JString, argName)

  # TODO: fromHex (and thus parse) call seems to let pass several invalid
  # UInt256.
  result = UInt256.fromHex(n.getStr())

# TODO: This one should go to nim-json-rpc but before we can do that we will
# have to update the vendor module to the current latest.
func fromJson*(n: JsonNode, argName: string, result: var uint16)
    {.raises: [ValueError].} =
  n.kind.expect(JInt, argName)
  let asInt = n.getBiggestInt()
  if asInt < 0:
    raise newException(
      ValueError, "JSON-RPC input is an unexpected negative value")
  if asInt > BiggestInt(uint16.high()):
    raise newException(
      ValueError, "JSON-RPC input is too large for uint32")

  result = uint16(asInt)
