# Nimbus - Portal Network- Message types
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# As per spec:
# https://github.com/ethereum/stateless-ethereum-specs/blob/master/state-network.md#wire-protocol

{.push raises: [Defect].}

import
  stint, stew/[results, objects],
  eth/ssz/ssz_serialization

export ssz_serialization, stint

type
  ByteList* = List[byte, 2048]

  MessageKind* = enum
    unused = 0x00

    ping = 0x01
    pong = 0x02
    findnode = 0x03
    nodes = 0x04
    findcontent = 0x05
    foundcontent = 0x06
    advertise = 0x07
    requestproofs = 0x08

  PingMessage* = object
    enrSeq*: uint64
    dataRadius*: UInt256

  PongMessage* = object
    enrSeq*: uint64
    dataRadius*: UInt256

  FindNodeMessage* = object
    distances*: List[uint16, 256]

  NodesMessage* = object
    total*: uint8
    enrs*: List[ByteList, 32] # ByteList here is the rlp encoded ENR. This could
    # also be limited to 300 bytes instead of 2048

  FindContentMessage* = object
    contentKey*: ByteList

  FoundContentMessage* = object
    enrs*: List[ByteList, 32]
    payload*: ByteList

  AdvertiseMessage* = List[ByteList, 32] # No container, heh...

  # This would be more consistent with the other messages
  # AdvertiseMessage* = object
  #   contentKeys*: List[ByteList, 32]

  RequestProofsMessage* = object
    connectionId*: List[byte, 4]
    contentKeys*: List[ByteList, 32]

  Message* = object
    case kind*: MessageKind
    of ping:
      ping*: PingMessage
    of pong:
      pong*: PongMessage
    of findnode:
      findNode*: FindNodeMessage
    of nodes:
      nodes*: NodesMessage
    of findcontent:
      findcontent*: FindContentMessage
    of foundcontent:
      foundcontent*: FoundContentMessage
    of advertise:
      advertise*: AdvertiseMessage
    of requestproofs:
      requestproofs*: RequestProofsMessage
    else:
      discard

  SomeMessage* =
    PingMessage or PongMessage or
    FindNodeMessage or NodesMessage or
    FindContentMessage or FoundContentMessage or
    AdvertiseMessage or RequestProofsMessage

template messageKind*(T: typedesc[SomeMessage]): MessageKind =
  when T is PingMessage: ping
  elif T is PongMessage: pong
  elif T is FindNodeMessage: findNode
  elif T is NodesMessage: nodes
  elif T is FindContentMessage: findcontent
  elif T is FoundContentMessage: foundcontent
  elif T is AdvertiseMessage: advertise
  elif T is RequestProofsMessage: requestproofs

template toSszType*(x: auto): auto =
  mixin toSszType

  when x is UInt256: toBytesLE(x)
  else: x

func fromSszBytes*(T: type UInt256, data: openArray[byte]):
    T {.raises: [MalformedSszError, Defect].} =
  if data.len != sizeof(result):
    raiseIncorrectSize T

  T.fromBytesLE(data)

proc encodeMessage*[T: SomeMessage](m: T): seq[byte] =
  ord(messageKind(T)).byte & SSZ.encode(m)

proc decodeMessage*(body: openarray[byte]): Result[Message, cstring] =
  # Decodes to the specific `Message` type.
  if body.len < 1:
    return err("No message data")

  var kind: MessageKind
  if not checkedEnumAssign(kind, body[0]):
    return err("Invalid message type")

  var message = Message(kind: kind)

  try:
    case kind
    of unused: return err("Invalid message type")
    of ping:
      message.ping = SSZ.decode(body.toOpenArray(1, body.high), PingMessage)
    of pong:
      message.pong = SSZ.decode(body.toOpenArray(1, body.high), PongMessage)
    of findNode:
      message.findNode = SSZ.decode(body.toOpenArray(1, body.high), FindNodeMessage)
    of nodes:
      message.nodes = SSZ.decode(body.toOpenArray(1, body.high), NodesMessage)
    of findcontent:
      message.findcontent = SSZ.decode(body.toOpenArray(1, body.high), FindContentMessage)
    of foundcontent:
      message.foundcontent = SSZ.decode(body.toOpenArray(1, body.high), FoundContentMessage)
    of advertise:
      message.advertise = SSZ.decode(body.toOpenArray(1, body.high), AdvertiseMessage)
    of requestproofs:
      message.requestproofs = SSZ.decode(body.toOpenArray(1, body.high), RequestProofsMessage)
  except SszError:
    return err("Invalid message encoding")

  ok(message)
