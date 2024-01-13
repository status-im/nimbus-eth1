# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  stint,
  json_rpc/jsonmarshal,
  stew/[results, byteutils],
  eth/p2p/discoveryv5/[routing_table, enr, node]

export jsonmarshal, routing_table, enr, node

type
  NodeInfo* = object
    enr*: Record
    nodeId*: NodeId

  RoutingTableInfo* = object
    localNodeId*: NodeId
    buckets*: seq[seq[NodeId]]

  PingResult* = tuple[enrSeq: uint64, dataRadius: UInt256]

NodeInfo.useDefaultSerializationIn JrpcConv
RoutingTableInfo.useDefaultSerializationIn JrpcConv
(string,string).useDefaultSerializationIn JrpcConv

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

proc writeValue*(w: var JsonWriter[JrpcConv], v: Record)
      {.gcsafe, raises: [IOError].} =
  w.writeValue(v.toURI())

proc readValue*(r: var JsonReader[JrpcConv], val: var Record)
       {.gcsafe, raises: [IOError, JsonReaderError].} =
  if not fromURI(val, r.parseString()):
    r.raiseUnexpectedValue("Invalid ENR")

proc writeValue*(w: var JsonWriter[JrpcConv], v: NodeId)
      {.gcsafe, raises: [IOError].} =
  w.writeValue("0x" & v.toHex())

proc writeValue*(w: var JsonWriter[JrpcConv], v: Opt[NodeId])
      {.gcsafe, raises: [IOError].} =
  if v.isSome():
    w.writeValue("0x" & v.get().toHex())
  else:
    w.writeValue("0x")

proc readValue*(r: var JsonReader[JrpcConv], val: var NodeId)
       {.gcsafe, raises: [IOError, JsonReaderError].} =
  try:
    val = NodeId.fromHex(r.parseString())
  except ValueError as exc:
    r.raiseUnexpectedValue("NodeId parser error: " & exc.msg)

proc writeValue*(w: var JsonWriter[JrpcConv], v: Opt[seq[byte]])
      {.gcsafe, raises: [IOError].} =
  if v.isSome():
    w.writeValue(v.get().to0xHex())
  else:
    w.writeValue("0x")

proc readValue*(r: var JsonReader[JrpcConv], val: var seq[byte])
       {.gcsafe, raises: [IOError, JsonReaderError].} =
  try:
    val = hexToSeqByte(r.parseString())
  except ValueError as exc:
    r.raiseUnexpectedValue("seq[byte] parser error: " & exc.msg)

proc writeValue*(w: var JsonWriter[JrpcConv], v: PingResult)
      {.gcsafe, raises: [IOError].} =
  w.beginRecord()
  w.writeField("enrSeq", v.enrSeq)
  w.writeField("dataRadius", "0x" & v.dataRadius.toHex)
  w.endRecord()

proc readValue*(r: var JsonReader[JrpcConv], val: var PingResult)
       {.gcsafe, raises: [IOError, SerializationError].} =
  try:
    for field in r.readObjectFields():
      case field:
      of "enrSeq": val.enrSeq = r.parseInt(uint64)
      of "dataRadius": val.dataRadius = UInt256.fromHex(r.parseString())
      else: discard
  except ValueError as exc:
    r.raiseUnexpectedValue("PingResult parser error: " & exc.msg)
