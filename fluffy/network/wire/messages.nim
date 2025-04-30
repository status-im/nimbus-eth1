# Nimbus - Portal Network- Message types
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## Definitions and encoding of the messages of the Portal wire protocol:
## https://github.com/ethereum/portal-network-specs/blob/master/portal-wire-protocol.md#request---response-messages

{.push raises: [].}

import
  stint, stew/[objects, endians2], ssz_serialization, ../../common/common_types, results

export ssz_serialization, stint, common_types

const
  contentKeysLimit* = 64
  # overhead of content message is a result of 1byte for kind enum, and
  # 4 bytes for offset in ssz serialization
  offerMessageOverhead* = 5

  # each key in ContentKeysList has uint32 offset which results in 4 bytes per
  # key overhead when serialized
  perContentKeyOverhead* = 4

  # Accept codes for the portal wire v1 accept message
  Accepted* = byte 0x0
  DeclinedGeneric* = byte 0x1
  DeclinedAlreadyStored* = byte 0x2
  DeclinedNotWithinRadius* = byte 0x3
  DeclinedRateLimited* = byte 0x4
  DeclinedInboundTransferInProgress* = byte 0x5

type
  ContentKeysList* = List[ContentKeyByteList, contentKeysLimit]
  ContentKeysAcceptList* = ByteList[contentKeysLimit]

  MessageKind* = enum
    ping = 0x00
    pong = 0x01
    findNodes = 0x02
    nodes = 0x03
    findContent = 0x04
    content = 0x05
    offer = 0x06
    accept = 0x07

  ContentMessageType* = enum
    connectionIdType = 0x00
    contentType = 0x01
    enrsType = 0x02

  PingMessage* = object
    enrSeq*: uint64
    payload_type*: uint16
    payload*: ByteList[1100]

  PongMessage* = object
    enrSeq*: uint64
    payload_type*: uint16
    payload*: ByteList[1100]

  FindNodesMessage* = object
    distances*: List[uint16, 256]

  NodesMessage* = object
    total*: uint8
    enrs*: List[ByteList[2048], 32]
      # ByteList[2048] here is the rlp encoded ENR. This could
    # also be limited to ~300 bytes instead of 2048

  FindContentMessage* = object
    contentKey*: ContentKeyByteList

  ContentMessage* = object
    case contentMessageType*: ContentMessageType
    of connectionIdType:
      connectionId*: Bytes2
    of contentType:
      content*: ByteList[2048]
    of enrsType:
      enrs*: List[ByteList[2048], 32]

  OfferMessage* = object
    contentKeys*: ContentKeysList

  AcceptMessage* = object
    connectionId*: Bytes2
    contentKeys*: ContentKeysAcceptList

  Message* = object
    case kind*: MessageKind
    of ping:
      ping*: PingMessage
    of pong:
      pong*: PongMessage
    of findNodes:
      findNodes*: FindNodesMessage
    of nodes:
      nodes*: NodesMessage
    of findContent:
      findContent*: FindContentMessage
    of content:
      content*: ContentMessage
    of offer:
      offer*: OfferMessage
    of accept:
      accept*: AcceptMessage

  SomeMessageV1* =
    PingMessage or PongMessage or FindNodesMessage or NodesMessage or FindContentMessage or
    ContentMessage or OfferMessage or AcceptMessage

  # Portal wire v0 protocol messages
  ContentKeysBitList* = BitList[contentKeysLimit]

  AcceptMessageV0* = object
    connectionId*: Bytes2
    contentKeys*: ContentKeysBitList

  MessageV0* = object
    case kind*: MessageKind
    of ping:
      ping*: PingMessage
    of pong:
      pong*: PongMessage
    of findNodes:
      findNodes*: FindNodesMessage
    of nodes:
      nodes*: NodesMessage
    of findContent:
      findContent*: FindContentMessage
    of content:
      content*: ContentMessage
    of offer:
      offer*: OfferMessage
    of accept:
      accept*: AcceptMessageV0

  SomeMessageV0* =
    PingMessage or PongMessage or FindNodesMessage or NodesMessage or FindContentMessage or
    ContentMessage or OfferMessage or AcceptMessageV0

  SomeMessage* = SomeMessageV0 or SomeMessageV1

template messageKind*(T: typedesc[SomeMessage]): MessageKind =
  when T is PingMessage:
    ping
  elif T is PongMessage:
    pong
  elif T is FindNodesMessage:
    findNodes
  elif T is NodesMessage:
    nodes
  elif T is FindContentMessage:
    findContent
  elif T is ContentMessage:
    content
  elif T is OfferMessage:
    offer
  elif T is AcceptMessage:
    accept

template toSszType*(x: UInt256): array[32, byte] =
  toBytesLE(x)

func fromSszBytes*(
    T: type UInt256, data: openArray[byte]
): T {.raises: [MalformedSszError].} =
  if data.len != sizeof(result):
    raiseIncorrectSize T

  T.fromBytesLE(data)

# To convert from portal wire v0 BitList to v1 ByteList
func fromBitList*(T: type ContentKeysAcceptList, bitList: ContentKeysBitList): T =
  var contentKeysAcceptList = ContentKeysAcceptList.init(@[])
  for bit in bitList:
    if bit:
      discard contentKeysAcceptList.add(Accepted)
    else:
      discard contentKeysAcceptList.add(DeclinedGeneric)

  contentKeysAcceptList

# To convert from portal wire accept v0 to accept v1
func fromAcceptMessageV0(T: type AcceptMessage, accept: AcceptMessageV0): T =
  AcceptMessage(
    connectionId: accept.connectionId,
    contentKeys: ContentKeysAcceptList.fromBitList(accept.contentKeys),
  )

# To convert from portal wire v0 message to v1 message
func fromMessageV0(T: type Message, message: MessageV0): Message =
  if message.kind == ping:
    Message(kind: ping, ping: message.ping)
  elif message.kind == pong:
    Message(kind: pong, pong: message.pong)
  elif message.kind == findNodes:
    Message(kind: findNodes, findNodes: message.findNodes)
  elif message.kind == nodes:
    Message(kind: nodes, nodes: message.nodes)
  elif message.kind == findContent:
    Message(kind: findContent, findContent: message.findContent)
  elif message.kind == content:
    Message(kind: content, content: message.content)
  elif message.kind == offer:
    Message(kind: offer, offer: message.offer)
  elif message.kind == accept:
    Message(kind: accept, accept: AcceptMessage.fromAcceptMessageV0(message.accept))
  else:
    raiseAssert("Invalid message kind")

# To convert from portal wire v1 ByteList to v0 BitList
func fromByteList*(T: type ContentKeysBitList, byteList: ContentKeysAcceptList): T =
  var contentKeysBitList = ContentKeysBitList.init(byteList.len)
  for i, b in byteList:
    if b == Accepted:
      contentKeysBitList.setBit(i)

  contentKeysBitList

# To convert from portal wire accept v1 to accept v0
func fromAcceptMessage*(T: type AcceptMessageV0, accept: AcceptMessage): T =
  AcceptMessageV0(
    connectionId: accept.connectionId,
    contentKeys: ContentKeysBitList.fromByteList(accept.contentKeys),
  )

func encodeMessage*[T: SomeMessage](m: T): seq[byte] =
  when T is PingMessage:
    SSZ.encode(Message(kind: ping, ping: m))
  elif T is PongMessage:
    SSZ.encode(Message(kind: pong, pong: m))
  elif T is FindNodesMessage:
    SSZ.encode(Message(kind: findNodes, findNodes: m))
  elif T is NodesMessage:
    SSZ.encode(Message(kind: nodes, nodes: m))
  elif T is FindContentMessage:
    SSZ.encode(Message(kind: findContent, findContent: m))
  elif T is ContentMessage:
    SSZ.encode(Message(kind: content, content: m))
  elif T is OfferMessage:
    SSZ.encode(Message(kind: offer, offer: m))
  elif T is AcceptMessage:
    SSZ.encode(Message(kind: accept, accept: m))
  elif T is AcceptMessageV0:
    SSZ.encode(MessageV0(kind: accept, accept: m))

func decodeMessage*(
    body: openArray[byte], version: uint8 = 1'u8
): Result[Message, string] =
  try:
    if body.len < 1: # TODO: This check should probably move a layer down
      return err("No message data, peer might not support this talk protocol")
    if version >= 1'u8:
      ok(SSZ.decode(body, Message))
    else:
      let message = SSZ.decode(body, MessageV0)
      # convert to V1 message so that the rest of the code base can work with
      # the same type.
      ok(Message.fromMessageV0(message))
  except SerializationError as e:
    err("Invalid message encoding: " & e.msg)

template innerMessage[T: SomeMessage](
    message: Message, expected: MessageKind
): Result[T, string] =
  if (message.kind == expected):
    ok(message.expected)
  else:
    err("Invalid message response")

# Each `Message` variants corresponds to an MessageKind. Therefore, the inner
# message can be extracted when providing the expected message type T.
# If the message does not hold the expacted variant, return error.
func getInnerMessage*[T: SomeMessage](m: Message): Result[T, string] =
  innerMessage[T](m, messageKind(T))

func getTalkReqOverhead*(protocolIdLen: int): int =
  return (
    16 + # IV size
    55 + # header size
    1 + # talkReq msg id
    3 + # rlp encoding outer list, max length will be encoded in 2 bytes
    9 + # request id (max = 8) + 1 byte from rlp encoding byte string
    protocolIdLen + 1 + # + 1 is necessary due to rlp encoding of byte string
    3 + # rlp encoding response byte string, max length in 2 bytes
    16 # HMAC
  )

func getTalkReqOverhead*(protocolId: openArray[byte]): int =
  return getTalkReqOverhead(len(protocolId))
