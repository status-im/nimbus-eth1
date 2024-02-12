# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  testutils/unittests,
  stew/[byteutils, io2],
  eth/keys,
  ../../network/state/state_content


suite "State Content Keys":
  const evenNibles = "008679e8ed"
  test "Encode/decode even nibbles":
    const
      nibbles: seq[byte] = @[8, 6, 7, 9, 14, 8, 14, 13]
      packedNibbles = packNibbles(nibbles)
      unpackedNibbles = unpackNibbles(packedNibbles)

    let
      encoded = SSZ.encode(packedNibbles)

    check encoded.toHex() == evenNibles
    check unpackedNibbles == nibbles

  const oddNibbles = "138679e8ed"
  test "Encode/decode odd nibbles":
    const
      nibbles: seq[byte] = @[3, 8, 6, 7, 9, 14, 8, 14, 13]
      packedNibbles = packNibbles(nibbles)
      unpackedNibbles = unpackNibbles(packedNibbles)

    let
      encoded = SSZ.encode(packedNibbles)
    
    check encoded.toHex() == oddNibbles
    check unpackedNibbles == nibbles

  const accountTrieNodeKeyEncoded = "20240000006225fcc63b22b80301d9f2582014e450e91f9b329b7cc87ad16894722fff5296008679e8ed"
  test "Encode/decode AccountTrieNodeKey":
    const
      nibbles: seq[byte] = @[8, 6, 7, 9, 14, 8, 14, 13]
      packedNibbles = packNibbles(nibbles)
      nodeHash = NodeHash.fromHex("6225fcc63b22b80301d9f2582014e450e91f9b329b7cc87ad16894722fff5296")

    let
      accountTrieNodeKey = AccountTrieNodeKey(path: packedNibbles, nodeHash: nodeHash)
      contentKey = ContentKey(contentType: accountTrieNode, accountTrieNodeKey: accountTrieNodeKey)
      encoded = contentKey.encode()
    check $encoded == accountTrieNodeKeyEncoded

    let decoded = encoded.decode().valueOr:
      raiseAssert "Cannot decode AccountTrieNodeKey"
    check:
      decoded.contentType == accountTrieNode
      decoded.accountTrieNodeKey == AccountTrieNodeKey(path: packedNibbles, nodeHash: nodeHash)

  const contractTrieNodeKeyEncoded = "21c02aaa39b223fe8d0a0e5c4f27ead9083c756cc238000000eb43d68008d216e753fef198cf51077f5a89f406d9c244119d1643f0f2b1901100405787"
  test "Encode/decode ContractTrieNodeKey":
    const
      nibbles: seq[byte] = @[4, 0, 5, 7, 8, 7]
      packedNibbles = packNibbles(nibbles)
      address = Address.fromHex("c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2")
      nodeHash = NodeHash.fromHex("eb43d68008d216e753fef198cf51077f5a89f406d9c244119d1643f0f2b19011")

    let
      contractTrieNodeKey = ContractTrieNodeKey(address: address, path: packedNibbles, nodeHash: nodeHash)
      contentKey = ContentKey(contentType: contractTrieNode, contractTrieNodeKey: contractTrieNodeKey)
      encoded = contentKey.encode()
    check $encoded == contractTrieNodeKeyEncoded

    let decoded = encoded.decode().valueOr:
      raiseAssert "Cannot decode ContractTrieNodeKey"
    check:
      decoded.contentType == contractTrieNode
      decoded.contractTrieNodeKey == ContractTrieNodeKey(address: address, path: packedNibbles, nodeHash: nodeHash)

  const contractCodeKeyEncoded = "22c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2d0a06b12ac47863b5c7be4185c2deaad1c61557033f56c7d4ea74429cbb25e23"
  test "Encode/decode ContractCodeKey":
    const
      address = Address.fromHex("c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2")
      codeHash = CodeHash.fromHex("d0a06b12ac47863b5c7be4185c2deaad1c61557033f56c7d4ea74429cbb25e23")

    let
      contractCodeKey = ContractCodeKey(address: address, codeHash: codeHash)
      contentKey = ContentKey(contentType: contractCode, contractCodeKey: contractCodeKey)
      encoded = contentKey.encode()
    check $encoded == contractCodeKeyEncoded

    let decoded = encoded.decode().valueOr:
      raiseAssert "Cannot decode ContractCodeKey"
    check:
      decoded.contentType == contractCode
      decoded.contractCodeKey.address == address
      decoded.contractCodeKey.codeHash == codeHash

  test "Invalid prefix - 0 value":
    let encoded =  ByteList.init(@[byte 0x00])
    let decoded = decode(encoded)

    check decoded.isNone()

  test "Invalid prefix - before valid range":
    let encoded = ByteList.init(@[byte 0x01])
    let decoded = decode(encoded)

    check decoded.isNone()

  test "Invalid prefix - after valid range":
    let encoded = ByteList.init(@[byte 0x25])
    let decoded = decode(encoded)

    check decoded.isNone()

  test "Invalid key - empty input":
    let encoded = ByteList.init(@[])
    let decoded = decode(encoded)

    check decoded.isNone()
