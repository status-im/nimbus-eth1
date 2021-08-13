# Nimbus - Portal Network- Message types
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# As per spec:
# https://notes.ethereum.org/tPzmxQD_S3S3uvtpUSA0-g

{.push raises: [Defect].}

import
  options,
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

  PingMessage* = object
    enrSeq*: uint64
    subProtocolId*: ByteList
    subProtocolPayload*: ByteList

  PongMessage* = object
    enrSeq*: uint64
    subProtocolId*: ByteList
    subProtocolPayload*: ByteList

  FindNodeMessage* = object
    subProtocolId*: ByteList
    distances*: List[uint16, 256]

  NodesMessage* = object
    subProtocolId*: ByteList
    total*: uint8
    enrs*: List[ByteList, 32] # ByteList here is the rlp encoded ENR. This could
    # also be limited to 300 bytes instead of 2048

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
    else:
      discard

  OverlayMessage* =
    PingMessage or PongMessage or
    FindNodeMessage or NodesMessage

template messageKind*(T: typedesc[OverlayMessage]): MessageKind =
  when T is PingMessage: ping
  elif T is PongMessage: pong
  elif T is FindNodeMessage: findNode
  elif T is NodesMessage: nodes

template toSszType*(x: auto): auto =
  x

# TODO consider using faststreams here to avoid copying like:
# outputStream.write ord(messageKind(T)).byte
# let sszWriter = SszWriter.init(outputStream)
# sszWriter.writeValue m
proc encodeMessage*(m: OverlayMessage): seq[byte] =
  type T = typeof(m)
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
  except SszError:
    return err("Invalid message encoding")

  ok(message)

template innerMessage(T: typedesc[OverlayMessage], message: Message, expected: MessageKind): Option[T] =
  if (message.kind == expected):
    some[T](message.expected)
  else:
    none[T]()

# All our Message variants coresponds to enum MessageKind, therefore we are able to
# zoom in on inner structure of message by defining expected type T.
# If expected variant is not active, retrun None
proc getInnnerMessage*(T: typedesc[OverlayMessage], m: Message): Option[T] =
  innerMessage(T, m, messageKind(T))

# Simple conversion from Option to Result, looks like somethif which coul live in
# Result library.
proc optToResult*(T: typedesc, E: typedesc, opt: Option[T], e: E): Result[T, E] =
  if (opt.isSome()):
    ok(opt.unsafeGet())
  else:
    err(e)

proc getInnerMessageResult*(T: typedesc[OverlayMessage], m: Message, errMessage: cstring): Result[T, cstring] =
  optToResult(T, cstring, getInnnerMessage(T, m), errMessage)
