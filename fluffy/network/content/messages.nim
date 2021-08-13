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
  nimcrypto/[sha2, hash],
  stint, stew/[results, objects],
  eth/ssz/ssz_serialization

export ssz_serialization, stint

type
  ByteList* = List[byte, 2048]

  ContentKey* = ByteList

  Content* = ByteList

  ContentId* = MDigest[32 * 8]

  MessageKind* = enum
    unused = 0x00

    findcontent = 0x01
    content = 0x02

  FindContentMessage* = object
    subProtocolId*: ByteList
    contentKey*: ContentKey

  ContentMessage* = object
    subProtocolId*: ByteList
    enrs*: List[ByteList, 32]
    payload*: Content

  Message* = object
    case kind*: MessageKind
    of findcontent:
      findcontent*: FindContentMessage
    of content:
      content*: ContentMessage
    else:
      discard

  ContentProtocolMessage* = FindContentMessage or ContentMessage

template messageKind*(T: typedesc[ContentProtocolMessage]): MessageKind =
  when T is FindContentMessage: findcontent
  elif T is ContentMessage: content

template toSszType*(x: auto): auto =
  x

proc encodeMessage*(m: ContentProtocolMessage): seq[byte] =
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
    of findcontent:
      message.findcontent = SSZ.decode(body.toOpenArray(1, body.high), FindContentMessage)
    of content:
      message.content = SSZ.decode(body.toOpenArray(1, body.high), ContentMessage)
  except SszError:
    return err("Invalid message encoding")

  ok(message)

func toContentId*(contentKey: ContentKey): ContentId =
  # TODO: Hash function to be defined, sha256 used now, might be confusing
  # with keccak256 that is used for the actual nodes:
  # https://github.com/ethereum/stateless-ethereum-specs/blob/master/state-network.md#content
  sha2.sha_256.digest(SSZ.encode(contentKey))
