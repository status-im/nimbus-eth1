# Nimbus - Portal Network
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  std/unittest,
  stint, stew/[byteutils, results],
  ../network/messages

suite "Portal Protocol Message Encodings":
  test "Ping Request":
    var dataRadius: UInt256
    let
      enrSeq = 1'u64
      p = PingMessage(enrSeq: enrSeq, dataRadius: dataRadius)

    let encoded = encodeMessage(p)
    check encoded.toHex ==
      "0101000000000000000000000000000000000000000000000000000000000000000000000000000000"
    let decoded = decodeMessage(encoded)
    check decoded.isOk()

    let message = decoded.get()
    check:
      message.kind == ping
      message.ping.enrSeq == enrSeq
      message.ping.dataRadius == dataRadius

  test "Pong Response":
    var dataRadius: UInt256
    let
      enrSeq = 1'u64
      p = PongMessage(enrSeq: enrSeq, dataRadius: dataRadius)

    let encoded = encodeMessage(p)
    check encoded.toHex ==
      "0201000000000000000000000000000000000000000000000000000000000000000000000000000000"
    let decoded = decodeMessage(encoded)
    check decoded.isOk()

    let message = decoded.get()
    check:
      message.kind == pong
      message.pong.enrSeq == enrSeq
      message.pong.dataRadius == dataRadius

  test "FindNode Request":
    let
      distances = List[uint16, 256](@[0x0100'u16])
      fn = FindNodeMessage(distances: distances)

    let encoded = encodeMessage(fn)
    check encoded.toHex == "03040000000001"

    let decoded = decodeMessage(encoded)
    check decoded.isOk()

    let message = decoded.get()
    check:
      message.kind == findnode
      message.findnode.distances == distances

  test "Nodes Response (empty)":
    let
      total = 0x1'u8
      n = NodesMessage(total: total)

    let encoded = encodeMessage(n)
    check encoded.toHex == "040105000000"

    let decoded = decodeMessage(encoded)
    check decoded.isOk()

    let message = decoded.get()
    check:
      message.kind == nodes
      message.nodes.total == total
      message.nodes.enrs.len() == 0

  test "FindContent Request":
    var nodeHash: List[byte, 32]
    let
      contentKey = ContentKey(
        networkId: 0'u16,
        contentType: ContentType.Account,
        nodeHash: nodeHash)
      fn = FindContentMessage(contentKey: contentKey)

    let encoded = encodeMessage(fn)
    check encoded.toHex == "050400000000000107000000"

    let decoded = decodeMessage(encoded)
    check decoded.isOk()

    let message = decoded.get()
    check:
      message.kind == findcontent
      message.findcontent.contentKey == contentKey

  test "FoundContent Response (empty enrs)":
    let
      enrs = List[ByteList, 32](@[])
      payload = ByteList(@[byte 0x01, 0x02, 0x03])
      n = FoundContentMessage(enrs: enrs, payload: payload)

    let encoded = encodeMessage(n)
    check encoded.toHex == "060800000008000000010203"

    let decoded = decodeMessage(encoded)
    check decoded.isOk()

    let message = decoded.get()
    check:
      message.kind == foundcontent
      message.foundcontent.enrs.len() == 0
      message.foundcontent.payload == payload

  test "Advertise Request":
    let
      contentKeys = List[ByteList, 32](List(@[ByteList(@[byte 0x01, 0x02, 0x03])]))
      am = AdvertiseMessage(contentKeys)
      # am = AdvertiseMessage(contentKeys: contentKeys)

    let encoded = encodeMessage(am)
    check encoded.toHex == "0704000000010203"
                          #  "070400000004000000010203"

    let decoded = decodeMessage(encoded)
    check decoded.isOk()

    let message = decoded.get()
    check:
      message.kind == advertise
      message.advertise == contentKeys
      # message.advertise.contentKeys == contentKeys

  test "RequestProofs Response": # That sounds weird
    let
      connectionId = List[byte, 4](@[byte 0x01, 0x02, 0x03, 0x04])
      contentKeys =
        List[ByteList, 32](List(@[ByteList(@[byte 0x01, 0x02, 0x03])]))
      n = RequestProofsMessage(connectionId: connectionId,
        contentKeys: contentKeys)

    let encoded = encodeMessage(n)
    check encoded.toHex == "08080000000c0000000102030404000000010203"

    let decoded = decodeMessage(encoded)
    check decoded.isOk()

    let message = decoded.get()
    check:
      message.kind == requestproofs
      message.requestproofs.connectionId == connectionId
      message.requestproofs.contentKeys == contentKeys
