# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[os, json, sequtils],
  testutils/unittests,
  stew/[byteutils, io2],
  eth/keys,
  ../../network/state/state_content

suite "State Content Keys":
  const evenNibles = "0005000000123456789abc"
  test "Encode/decode even nibbles":
    const
      packedNibbles = Nibbles.packedNibbles.init(@[NibblePair 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC])
      isOddLength = false

    let
      nibbles = Nibbles(packedNibbles: packedNibbles, isOddLength: isOddLength)
      encoded = SSZ.encode(nibbles)
    check encoded.toHex() == evenNibles
    # echo ">>>", encoded.toHex()
      
  const oddNibbles = "0105000000123456789abc0d"
  test "Encode/decode odd nibbles":
    const
      packedNibbles = Nibbles.packedNibbles.init(@[NibblePair 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0x0D])
      isOddLength = true

    let
      nibbles = Nibbles(packedNibbles: packedNibbles, isOddLength: isOddLength)
      encoded = SSZ.encode(nibbles)
    check encoded.toHex() == oddNibbles
    # echo ">>>", encoded.toHex()

  const accountTrieNodeKeyEncoded = "2024000000c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a4700005000000123456789abc"
  test "Encode/decode AccountTrieNodeKey":
    const
      packedNibbles = Nibbles.packedNibbles.init(@[NibblePair 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC])
      isOddLength = false
      nodeHash = NodeHash.fromHex("c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")

    let
      nibbles = Nibbles(packedNibbles: packedNibbles, isOddLength: isOddLength)
      accountTrieNodeKey = AccountTrieNodeKey(path: nibbles, nodeHash: nodeHash)
      contentKey = ContentKey(contentType: accountTrieNode, accountTrieNodeKey: accountTrieNodeKey)
      encoded = contentKey.encode()
    # echo ">>>", $encoded
    check $encoded == accountTrieNodeKeyEncoded

    let decoded = encoded.decode().valueOr:
      raiseAssert "Cannot decode AccountTrieNodeKey"
    check:
      decoded.contentType == accountTrieNode
      decoded.accountTrieNodeKey == AccountTrieNodeKey(path: nibbles, nodeHash: nodeHash)

  const contractTrieNodeKeyEncoded = "21000d836201318ec6899a6754069038278074328038000000c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a4700005000000123456789abc"
  test "Encode/decode ContractTrieNodeKey":
    const
      address = Address.fromHex("000d836201318ec6899a67540690382780743280")
      packedNibbles = Nibbles.packedNibbles.init(@[NibblePair 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC])
      isOddLength = false
      nodeHash = NodeHash.fromHex("c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")

    let
      nibbles = Nibbles(packedNibbles: (packedNibbles), isOddLength: isOddLength)
      contractTrieNodeKey = ContractTrieNodeKey(address: address, path: nibbles, nodeHash: nodeHash)
      contentKey = ContentKey(contentType: contractTrieNode, contractTrieNodeKey: contractTrieNodeKey)
      encoded = contentKey.encode()
    # echo ">>>", $encoded
    check $encoded == contractTrieNodeKeyEncoded

    let decoded = encoded.decode().valueOr:
      raiseAssert "Cannot decode ContractTrieNodeKey"
    check:
      decoded.contentType == contractTrieNode
      decoded.contractTrieNodeKey == ContractTrieNodeKey(address: address, path: nibbles, nodeHash: nodeHash)

  const contractCodeKeyEncoded = "22000d836201318ec6899a67540690382780743280c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
  test "Encode/decode ContractCodeKey":
    const
      address = Address.fromHex("000d836201318ec6899a67540690382780743280")
      codeHash = CodeHash.fromHex("c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
      
    let
      contractCodeKey = ContractCodeKey(address: address, codeHash: codeHash)
      contentKey = ContentKey(contentType: contractCode, contractCodeKey: contractCodeKey)
      encoded = contentKey.encode()
    # echo ">>>", $encoded
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

suite "State Content Values":
  const accountTrieNodeOfferEncoded = "24000000d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa308000000130000000005000000123456789abc04000000010203040506"
  test "Encode/decode AccountTrieNodeOffer":
    let
      blockHash = "d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3"
      packedNibbles = @[NibblePair 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC]
      isOddLength = false
      key = Nibbles(packedNibbles: Nibbles.packedNibbles.init(packedNibbles), isOddLength: isOddLength)
      witnessNode = WitnessNode(@[byte 0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
      proof = Witness(@[witnessNode])

      accountTrieNodeOffer = AccountTrieNodeOffer(blockHash: BlockHash.fromHex(blockHash), proof: StateWitness(key: key, proof: proof))
      encoded = SSZ.encode(accountTrieNodeOffer)
    # echo ">>>", encoded.toHex()
    check encoded.toHex() == accountTrieNodeOfferEncoded

    let decoded = SSZ.decode(encoded, AccountTrieNodeOffer)
    check:
      decoded.blockHash == BlockHash.fromHex(blockHash)
      decoded.proof == StateWitness(key: key, proof: proof)

  const accountTrieNodeRetrievalEncoded = "04000000010203040506"
  test "Encode/decode AccountTrieNodeRetrieval":
    let
      witnessNode = WitnessNode(@[byte 0x01, 0x02, 0x03, 0x04, 0x05, 0x06])

      accountTrieNodeRetrieval = AccountTrieNodeRetrieval(node: witnessNode)
      encoded = SSZ.encode(accountTrieNodeRetrieval)
    # echo ">>>", encoded.toHex()
    check encoded.toHex() == accountTrieNodeRetrievalEncoded

    let decoded = SSZ.decode(encoded, AccountTrieNodeRetrieval)
    check decoded.node == witnessNode

  const contractTrieNodeOfferEncoded = "24000000d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa30c00000017000000220000000005000000123456789abc040000000102030405060708000000150000000005000000123456789abcdef104000000010203040506070809"
  test "Encode/decode ContractTrieNodeOffer":
    let
      blockHash = "d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3"
      contractWitnessKeyPackedNibbles = @[NibblePair 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC]
      contractWitnessProof = Witness(@[WitnessNode(@[byte 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])])
      stateWitnessKeyPackedNibbles = @[NibblePair 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF1]
      stateWitnessProof = Witness(@[WitnessNode(@[byte 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09])])
      
      contractTrieNodeOffer = ContractTrieNodeOffer(
        blockHash: BlockHash.fromHex(blockHash),
        proof: StorageWitness(
          key: Nibbles(packedNibbles: Nibbles.packedNibbles.init(contractWitnessKeyPackedNibbles), isOddLength: false),
          proof: contractWitnessProof,
          stateWitness: StateWitness(
            key: Nibbles(packedNibbles: Nibbles.packedNibbles.init(stateWitnessKeyPackedNibbles), isOddLength: false),
            proof: stateWitnessProof
          )))
      encoded = SSZ.encode(contractTrieNodeOffer)
    # echo ">>>", encoded.toHex()
    check encoded.toHex() == contractTrieNodeOfferEncoded

    let decoded = SSZ.decode(encoded, ContractTrieNodeOffer)
    check:
      decoded.blockHash == BlockHash.fromHex(blockHash)
      decoded.proof == StorageWitness(
        key: Nibbles(packedNibbles: Nibbles.packedNibbles.init(contractWitnessKeyPackedNibbles), isOddLength: false),
        proof: contractWitnessProof,
        stateWitness: StateWitness(
          key: Nibbles(packedNibbles: Nibbles.packedNibbles.init(stateWitnessKeyPackedNibbles), isOddLength: false),
          proof: stateWitnessProof
        ))

  const contractTrieNodeRetrievalEncoded = "04000000010203040506"
  test "Encode/decode ContractTrieNodeRetrieval":
    let
      witnessNode = WitnessNode(@[byte 0x01, 0x02, 0x03, 0x04, 0x05, 0x06])

      contractTrieNodeRetrieval = ContractTrieNodeRetrieval(node: witnessNode)
      encoded = SSZ.encode(contractTrieNodeRetrieval)
    # echo ">>>", encoded.toHex()
    check encoded.toHex() == contractTrieNodeRetrievalEncoded

    let decoded = SSZ.decode(encoded, ContractTrieNodeRetrieval)
    check decoded.node == witnessNode

  const contractCodeOfferEncoded = "2800000036000000d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3010203040506070809a0a1a2a3a408000000130000000005000000123456789abc04000000010203040506"
  test "Encode/decode ContractCodeOffer":
    let
      code = @[byte 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4]
      blockHash = "d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3"
      accountProofKey = Nibbles(packedNibbles: Nibbles.packedNibbles.init(@[NibblePair 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC]), isOddLength: false)
      accountProofWitness = Witness(@[WitnessNode(@[byte 0x01, 0x02, 0x03, 0x04, 0x05, 0x06])])

      contractCodeOffer = ContractCodeOffer(
        code: ByteList.init(code),
        blockHash: BlockHash.fromHex(blockHash),
        accountProof: StateWitness(key: accountProofKey, proof: accountProofWitness))
      encoded = SSZ.encode(contractCodeOffer)
    # echo ">>>", encoded.toHex()
    check encoded.toHex() == contractCodeOfferEncoded

    let decoded = SSZ.decode(encoded, ContractCodeOffer)
    check:
      decoded.code == ByteList.init(code)
      decoded.blockHash == BlockHash.fromHex(blockHash)
      decoded.accountProof == StateWitness(key: accountProofKey, proof: accountProofWitness)

  const contractCodeRetrievalEncoded = "04000000010203040506070809a0a1a2a3a4"
  test "Encode/decode ContractCodeRetrieval":
    let
      code = @[byte 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4]

      contractCodeRetrieval = ContractCodeRetrieval(code: ByteList.init(code))
      encoded = SSZ.encode(contractCodeRetrieval)
    # echo ">>>", encoded.toHex()
    check encoded.toHex() == contractCodeRetrievalEncoded

    let decoded = SSZ.decode(encoded, ContractCodeRetrieval)
    check decoded.code == ByteList.init(code)
