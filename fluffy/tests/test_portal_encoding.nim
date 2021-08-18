# Nimbus - Portal Network
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  std/unittest,
  stint, stew/[byteutils, results], eth/p2p/discoveryv5/enr,
  ../network/state/messages

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

  test "Nodes Response - empty":
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

  test "Nodes Response - enr":
    var e1, e2: Record
    check:
      e1.fromURI("enr:-HW4QBzimRxkmT18hMKaAL3IcZF1UcfTMPyi3Q1pxwZZbcZVRI8DC5infUAB_UauARLOJtYTxaagKoGmIjzQxO2qUygBgmlkgnY0iXNlY3AyNTZrMaEDymNMrg1JrLQB2KTGtv6MVbcNEVv0AHacwUAPMljNMTg")
      e2.fromURI("enr:-HW4QNfxw543Ypf4HXKXdYxkyzfcxcO-6p9X986WldfVpnVTQX1xlTnWrktEWUbeTZnmgOuAY_KUhbVV1Ft98WoYUBMBgmlkgnY0iXNlY3AyNTZrMaEDDiy3QkHAxPyOgWbxp5oF1bDdlYE6dLCUUp8xfVw50jU")

    let
      total = 0x1'u8
      n = NodesMessage(total: total, enrs: List[ByteList, 32](@[ByteList(e1.raw), ByteList(e2.raw)]))

    let encoded = encodeMessage(n)
    check encoded.toHex == "040105000000080000007f000000f875b8401ce2991c64993d7c84c29a00bdc871917551c7d330fca2dd0d69c706596dc655448f030b98a77d4001fd46ae0112ce26d613c5a6a02a81a6223cd0c4edaa53280182696482763489736563703235366b31a103ca634cae0d49acb401d8a4c6b6fe8c55b70d115bf400769cc1400f3258cd3138f875b840d7f1c39e376297f81d7297758c64cb37dcc5c3beea9f57f7ce9695d7d5a67553417d719539d6ae4b445946de4d99e680eb8063f29485b555d45b7df16a1850130182696482763489736563703235366b31a1030e2cb74241c0c4fc8e8166f1a79a05d5b0dd95813a74b094529f317d5c39d235"

    let decoded = decodeMessage(encoded)
    check decoded.isOk()

    let message = decoded.get()
    check:
      message.kind == nodes
      message.nodes.total == total
      message.nodes.enrs.len() == 2
      message.nodes.enrs[0] == ByteList(e1.raw)
      message.nodes.enrs[1] == ByteList(e2.raw)

  test "FindContent Request":
    var nodeHash: NodeHash # zeroes hash
    let
      contentKey = ContentKey(
        networkId: 0'u16,
        contentType: ContentType.Account,
        nodeHash: nodeHash)

      contentEncoded: ByteList = encodeKeyAsList(contentKey)
      
      fn = FindContentMessage(contentKey: contentEncoded)

    let encoded = encodeMessage(fn)
    check encoded.toHex == "05040000000000010000000000000000000000000000000000000000000000000000000000000000"

    let decoded = decodeMessage(encoded)
    check decoded.isOk()
    
    let message = decoded.get()
    check:
      message.kind == findcontent
      message.findcontent.contentKey == contentEncoded

  test "FoundContent Response - payload":
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

  test "FoundContent Response - enrs":
    var e1, e2: Record
    check:
      e1.fromURI("enr:-HW4QBzimRxkmT18hMKaAL3IcZF1UcfTMPyi3Q1pxwZZbcZVRI8DC5infUAB_UauARLOJtYTxaagKoGmIjzQxO2qUygBgmlkgnY0iXNlY3AyNTZrMaEDymNMrg1JrLQB2KTGtv6MVbcNEVv0AHacwUAPMljNMTg")
      e2.fromURI("enr:-HW4QNfxw543Ypf4HXKXdYxkyzfcxcO-6p9X986WldfVpnVTQX1xlTnWrktEWUbeTZnmgOuAY_KUhbVV1Ft98WoYUBMBgmlkgnY0iXNlY3AyNTZrMaEDDiy3QkHAxPyOgWbxp5oF1bDdlYE6dLCUUp8xfVw50jU")

    let
      enrs = List[ByteList, 32](@[ByteList(e1.raw), ByteList(e2.raw)])
      payload = ByteList(@[])
      n = FoundContentMessage(enrs: enrs, payload: payload)

    let encoded = encodeMessage(n)
    check encoded.toHex == "0608000000fe000000080000007f000000f875b8401ce2991c64993d7c84c29a00bdc871917551c7d330fca2dd0d69c706596dc655448f030b98a77d4001fd46ae0112ce26d613c5a6a02a81a6223cd0c4edaa53280182696482763489736563703235366b31a103ca634cae0d49acb401d8a4c6b6fe8c55b70d115bf400769cc1400f3258cd3138f875b840d7f1c39e376297f81d7297758c64cb37dcc5c3beea9f57f7ce9695d7d5a67553417d719539d6ae4b445946de4d99e680eb8063f29485b555d45b7df16a1850130182696482763489736563703235366b31a1030e2cb74241c0c4fc8e8166f1a79a05d5b0dd95813a74b094529f317d5c39d235"

    let decoded = decodeMessage(encoded)
    check decoded.isOk()

    let message = decoded.get()
    check:
      message.kind == foundcontent
      message.foundcontent.enrs.len() == 2
      message.foundcontent.enrs[0] == ByteList(e1.raw)
      message.foundcontent.enrs[1] == ByteList(e2.raw)
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
