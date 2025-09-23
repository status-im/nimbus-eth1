# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  stint,
  json_rpc/[jsonmarshal, errors],
  stew/byteutils,
  results,
  eth/p2p/discoveryv5/[routing_table, enr, node],
  json_serialization/pkg/results

export jsonmarshal, routing_table, enr, node, results

# Portal Network JSON-RPC errors

const
  # These errors are defined in the portal jsonrpc spec: https://github.com/ethereum/portal-network-specs/tree/master/jsonrpc
  ContentNotFoundError* = (code: -39001, msg: "Content not found")
  ContentNotFoundErrorWithTrace* = (code: -39002, msg: "Content not found")
  PayloadTypeNotSupportedError* = (code: -39004, msg: "Payload type not supported")
  FailedToDecodePayloadError* = (code: -39005, msg: "Failed to decode payload")
  PayloadTypeRequiredError* =
    (code: -39006, msg: "Payload type is required if payload is specified")
  UserSpecifiedPayloadBlockedByClientError* = (
    code: -39007,
    msg: "The client has blocked users from specifying the payload for this extension",
  )

  # These errors are used by Nimbus Portal but are not yet in the spec
  InvalidContentKeyError* = (code: -32602, msg: "Invalid content key")
  InvalidContentValueError* = (code: -32603, msg: "Invalid content value")

template applicationError(error: (int, string)): auto =
  (ref ApplicationError)(code: error.code, msg: error.msg)

template contentNotFoundErr*(): auto =
  ContentNotFoundError.applicationError()

template contentNotFoundErrWithTrace*(data: typed): auto =
  (ref ApplicationError)(
    code: ContentNotFoundErrorWithTrace.code,
    msg: ContentNotFoundErrorWithTrace.msg,
    data: data,
  )

template payloadTypeNotSupportedError*(): auto =
  (ref ApplicationError)(
    code: PayloadTypeNotSupportedError.code,
    msg: PayloadTypeNotSupportedError.msg,
    data: Opt.some(JsonString("{ \"reason\" : \"client\" }")),
  )

template failedToDecodePayloadError*(): auto =
  FailedToDecodePayloadError.applicationError()

template payloadTypeRequiredError*(): auto =
  PayloadTypeRequiredError.applicationError()

template userSpecifiedPayloadBlockedByClientError*(): auto =
  UserSpecifiedPayloadBlockedByClientError.applicationError()

template invalidRequest*(error: (int, string)): auto =
  (ref errors.InvalidRequest)(code: error.code, msg: error.msg)

template invalidKeyErr*(): auto =
  InvalidContentKeyError.invalidRequest()

template invalidValueErr*(): auto =
  InvalidContentValueError.invalidRequest()

type
  NodeInfo* = object
    enr*: Record
    nodeId*: NodeId

  RoutingTableInfo* = object
    localNodeId*: NodeId
    buckets*: seq[seq[NodeId]]

  UnknownPayload* = tuple[]

  CapabilitiesPayload* =
    tuple[clientInfo: string, dataRadius: UInt256, capabilities: seq[uint16]]

  PingResult* = object
    enrSeq*: uint64
    payloadType*: uint16
    payload*: CapabilitiesPayload

  ContentInfo* = object
    content*: string
    utpTransfer*: bool

  ContentItem* = array[2, string]

  AcceptMetadata* = object
    acceptedCount*: int
    genericDeclineCount*: int
    alreadyStoredCount*: int
    notWithinRadiusCount*: int
    rateLimitedCount*: int
    transferInProgressCount*: int

  PutContentResult* = object
    storedLocally*: bool
    peerCount*: int
    acceptMetadata*: AcceptMetadata

NodeInfo.useDefaultSerializationIn JrpcConv
RoutingTableInfo.useDefaultSerializationIn JrpcConv
PingResult.useDefaultSerializationIn JrpcConv
(string, string).useDefaultSerializationIn JrpcConv
ContentInfo.useDefaultSerializationIn JrpcConv
AcceptMetadata.useDefaultSerializationIn JrpcConv
PutContentResult.useDefaultSerializationIn JrpcConv

JrpcConv.automaticSerialization(int, true)
JrpcConv.automaticSerialization(int64, true)
JrpcConv.automaticSerialization(uint64, true)
JrpcConv.automaticSerialization(uint16, true)
JrpcConv.automaticSerialization(seq, true)
JrpcConv.automaticSerialization(string, true)
JrpcConv.automaticSerialization(bool, true)
JrpcConv.automaticSerialization(JsonString, true)

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
  let node = Node.fromRecord(enr)
  if node.address.isNone():
    raise newException(ValueError, "ENR without address")
  else:
    node

proc writeValue*(w: var JsonWriter[JrpcConv], v: Record) {.gcsafe, raises: [IOError].} =
  w.writeValue(v.toURI())

proc readValue*(
    r: var JsonReader[JrpcConv], val: var Record
) {.gcsafe, raises: [IOError, JsonReaderError].} =
  val = Record.fromURI(r.parseString()).valueOr:
    r.raiseUnexpectedValue("Invalid ENR")

proc writeValue*(w: var JsonWriter[JrpcConv], v: NodeId) {.gcsafe, raises: [IOError].} =
  w.writeValue(v.toBytesBE().to0xHex())

proc writeValue*(
    w: var JsonWriter[JrpcConv], v: Opt[NodeId]
) {.gcsafe, raises: [IOError].} =
  if v.isSome():
    w.writeValue(v.get())
  else:
    w.writeValue(JsonString("null"))

proc readValue*(
    r: var JsonReader[JrpcConv], val: var NodeId
) {.gcsafe, raises: [IOError, JsonReaderError].} =
  try:
    val = NodeId.fromHex(r.parseString())
  except ValueError as exc:
    r.raiseUnexpectedValue("NodeId parser error: " & exc.msg)

proc writeValue*(
    w: var JsonWriter[JrpcConv], v: Opt[seq[byte]]
) {.gcsafe, raises: [IOError].} =
  if v.isSome():
    w.writeValue(v.get().to0xHex())
  else:
    w.writeValue("0x")

proc readValue*(
    r: var JsonReader[JrpcConv], val: var seq[byte]
) {.gcsafe, raises: [IOError, JsonReaderError].} =
  try:
    val = hexToSeqByte(r.parseString())
  except ValueError as exc:
    r.raiseUnexpectedValue("seq[byte] parser error: " & exc.msg)

proc writeValue*(
    w: var JsonWriter[JrpcConv], v: CapabilitiesPayload
) {.gcsafe, raises: [IOError].} =
  w.beginRecord()

  w.writeField("clientInfo", v.clientInfo)
  # Portal json-rpc specifications allows for dropping leading zeroes.
  w.writeField("dataRadius", "0x" & v.dataRadius.toHex())
  w.writeField("capabilities", v.capabilities)

  w.endRecord()

proc readValue*(
    r: var JsonReader[JrpcConv], val: var CapabilitiesPayload
) {.gcsafe, raises: [IOError, SerializationError].} =
  try:
    for field in r.readObjectFields():
      case field
      of "clientInfo":
        val.clientInfo = r.parseString()
      of "dataRadius":
        val.dataRadius = UInt256.fromHex(r.parseString())
      of "capabilities":
        r.parseArray:
          val.capabilities.add(r.parseInt(uint16))
      else:
        discard
  except ValueError as exc:
    r.raiseUnexpectedValue("PingResult parser error: " & exc.msg)

# Note:
# This is a similar readValue as the default one in nim-json-serialization but
# with an added exact length check. The default one will successfully parse when
# a JSON array with less than size n items is provided. And default objects
# (in this case empty string) will be applied for the missing items.
proc readValue*(
    r: var JsonReader[JrpcConv], value: var ContentItem
) {.gcsafe, raises: [IOError, SerializationError].} =
  type IDX = typeof low(value)
  var count = 0
  r.parseArray(idx):
    let i = IDX(idx + low(value).int)
    if i <= high(value):
      readValue(r, value[i])
      count.inc

  if count != value.len():
    r.raiseUnexpectedValue("Array length mismatch")

proc readValue*(
    r: var JsonReader[JrpcConv], val: var Opt[uint16]
) {.gcsafe, raises: [IOError, SerializationError].} =
  if r.tokKind == JsonValueKind.Null:
    reset val
    r.parseNull()
  else:
    val.ok r.readValue(uint16)

proc readValue*(
    r: var JsonReader[JrpcConv], val: var Opt[UnknownPayload]
) {.gcsafe, raises: [IOError, SerializationError].} =
  if r.tokKind == JsonValueKind.Null:
    reset val
    r.parseNull()
  else:
    val.ok default(UnknownPayload)
