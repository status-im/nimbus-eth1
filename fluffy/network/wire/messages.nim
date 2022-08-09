# Nimbus - Portal Network- Message types
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## Definitions and encoding of the messages of the Portal wire protocol:
## https://github.com/ethereum/portal-network-specs/blob/master/portal-wire-protocol.md#request---response-messages

{.push raises: [Defect].}

import
  std/options,
  stint, stew/[results, objects],
  ssz_serialization,
  ../../common/common_types

export ssz_serialization, stint, common_types

const
  contentKeysLimit* = 64
  # overhead of content message is a result of 1byte for kind enum, and
  # 4 bytes for offset in ssz serialization
  offerMessageOverhead* = 5

  # each key in ContentKeysList has uint32 offset which results in 4 bytes per
  # key overhead when serialized
  perContentKeyOverhead* = 4

type
  ContentKeysList* = List[ByteList, contentKeysLimit]
  ContentKeysBitList* = BitList[contentKeysLimit]

  # TODO: should become part of the specific networks, considering it is custom.
  CustomPayload* = object
    dataRadius*: UInt256

  MessageKind* = enum
    ping = 0x00
    pong = 0x01
    findnodes = 0x02
    nodes = 0x03
    findcontent = 0x04
    content = 0x05
    offer = 0x06
    accept = 0x07

  ContentMessageType* = enum
    connectionIdType = 0x00
    contentType = 0x01
    enrsType = 0x02

  PingMessage* = object
    enrSeq*: uint64
    customPayload*: ByteList

  PongMessage* = object
    enrSeq*: uint64
    customPayload*: ByteList

  FindNodesMessage* = object
    distances*: List[uint16, 256]

  NodesMessage* = object
    total*: uint8
    enrs*: List[ByteList, 32] # ByteList here is the rlp encoded ENR. This could
    # also be limited to ~300 bytes instead of 2048

  FindContentMessage* = object
    contentKey*: ByteList

  ContentMessage* = object
    case contentMessageType*: ContentMessageType
    of connectionIdType:
      connectionId*: Bytes2
    of contentType:
      content*: ByteList
    of enrsType:
      enrs*: List[ByteList, 32]

  OfferMessage* = object
    contentKeys*: ContentKeysList

  AcceptMessage* = object
    connectionId*: Bytes2
    contentKeys*: ContentKeysBitList

  Message* = object
    case kind*: MessageKind
    of ping:
      ping*: PingMessage
    of pong:
      pong*: PongMessage
    of findnodes:
      findnodes*: FindNodesMessage
    of nodes:
      nodes*: NodesMessage
    of findcontent:
      findcontent*: FindContentMessage
    of content:
      content*: ContentMessage
    of offer:
      offer*: OfferMessage
    of accept:
      accept*: AcceptMessage

  SomeMessage* =
    PingMessage or PongMessage or
    FindNodesMessage or NodesMessage or
    FindContentMessage or ContentMessage or
    OfferMessage or AcceptMessage

template messageKind*(T: typedesc[SomeMessage]): MessageKind =
  when T is PingMessage: ping
  elif T is PongMessage: pong
  elif T is FindNodesMessage: findnodes
  elif T is NodesMessage: nodes
  elif T is FindContentMessage: findcontent
  elif T is ContentMessage: content
  elif T is OfferMessage: offer
  elif T is AcceptMessage: accept

template toSszType*(x: UInt256): array[32, byte] =
  toBytesLE(x)

func fromSszBytes*(T: type UInt256, data: openArray[byte]):
    T {.raises: [Defect, MalformedSszError].} =
  if data.len != sizeof(result):
    raiseIncorrectSize T

  T.fromBytesLE(data)

func encodeMessage*[T: SomeMessage](m: T): seq[byte] =
  # TODO: Could/should be macro'd away,
  # or we just use SSZ.encode(Message) directly
  when T is PingMessage: SSZ.encode(Message(kind: ping, ping: m))
  elif T is PongMessage: SSZ.encode(Message(kind: pong, pong: m))
  elif T is FindNodesMessage: SSZ.encode(Message(kind: findnodes, findnodes: m))
  elif T is NodesMessage: SSZ.encode(Message(kind: nodes, nodes: m))
  elif T is FindContentMessage: SSZ.encode(Message(kind: findcontent, findcontent: m))
  elif T is ContentMessage: SSZ.encode(Message(kind: content, content: m))
  elif T is OfferMessage: SSZ.encode(Message(kind: offer, offer: m))
  elif T is AcceptMessage: SSZ.encode(Message(kind: accept, accept: m))

func decodeMessage*(body: openArray[byte]): Result[Message, cstring] =
  try:
    if body.len < 1: # TODO: This check should probably move a layer down
      return err("No message data, peer might not support this talk protocol")
    ok(SSZ.decode(body, Message))
  except SszError:
    err("Invalid message encoding")

template innerMessage[T: SomeMessage](message: Message, expected: MessageKind): Option[T] =
  if (message.kind == expected):
    some[T](message.expected)
  else:
    none[T]()

# All our Message variants correspond to enum MessageKind, therefore we are able to
# zoom in on inner structure of message by defining expected type T.
# If expected variant is not active, return None
func getInnnerMessage*[T: SomeMessage](m: Message): Option[T] =
  innerMessage[T](m, messageKind(T))

# Simple conversion from Option to Result, looks like something which could live in
# Result library.
func optToResult*[T, E](opt: Option[T], e: E): Result[T, E] =
  if (opt.isSome()):
    ok(opt.unsafeGet())
  else:
    err(e)

func getInnerMessageResult*[T: SomeMessage](m: Message, errMessage: cstring): Result[T, cstring] =
  optToResult(getInnnerMessage[T](m), errMessage)

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
