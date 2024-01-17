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
  eth/keys, eth/common/eth_types,
  ../../network/state/state_content

procSuite "State Content":
  let rng = newRng()

  const evenNibles = "0500000000123456789abc"
  test "Encode/decode even nibbles":
    let
      packedNibbles = @[NibblePair 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC]
      isOddLength = false

      nibbles = Nibbles(packedNibbles: Nibbles.packedNibbles.init(packedNibbles), isOddLength: isOddLength)
      encoded = SSZ.encode(nibbles)
    check encoded.toHex() == evenNibles
    # echo ">>>", encoded.toHex()
      
  const oddNibbles = "0500000001123456789abc0d"
  test "Encode/decode odd nibbles":
    let
      packedNibbles = @[NibblePair 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0x0D]
      isOddLength = true

      nibbles = Nibbles(packedNibbles: Nibbles.packedNibbles.init(packedNibbles), isOddLength: isOddLength)
      encoded = SSZ.encode(nibbles)
    check encoded.toHex() == oddNibbles
    # echo ">>>", encoded.toHex()

  const accountTrieNodeKeyEncoded = "24000000d7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f05440500000000123456789abc"
  test "Encode/decode AccountTrieNodeKey":
    let
      packedNibbles = @[NibblePair 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC]
      isOddLength = false
      nodeHash = "d7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544"

      nibbles = Nibbles(packedNibbles: Nibbles.packedNibbles.init(packedNibbles), isOddLength: isOddLength)
      accountTrieNodeKey = AccountTrieNodeKey(path: nibbles, nodeHash: NodeHash.fromHex(nodeHash))
      encoded = SSZ.encode(accountTrieNodeKey)
    # echo ">>>", encoded.toHex()
    check encoded.toHex() == accountTrieNodeKeyEncoded

    let decoded = SSZ.decode(encoded, AccountTrieNodeKey)
    check decoded.nodeHash == NodeHash.fromHex(nodeHash)
    check decoded.path.isOddLength == isOddLength
    check decoded.path.packedNibbles == Nibbles.packedNibbles.init(packedNibbles)

  const contractTrieNodeKeyEncoded = "000d836201318ec6899a6754069038278074328038000000d7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f05440500000000123456789abc"
  test "Encode/decode ContractTrieNodeKey":
    let
      address = "000d836201318ec6899a67540690382780743280"
      packedNibbles = @[NibblePair 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC]
      isOddLength = false
      nodeHash = "d7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544"

      nibbles = Nibbles(packedNibbles: Nibbles.packedNibbles.init(packedNibbles), isOddLength: isOddLength)
      contractTrieNodeKey = ContractTrieNodeKey(address: Address.fromHex(address), path: nibbles, nodeHash: NodeHash.fromHex(nodeHash))
      encoded = SSZ.encode(contractTrieNodeKey)
    # echo ">>>", encoded.toHex()
    check encoded.toHex() == contractTrieNodeKeyEncoded

    let decoded = SSZ.decode(encoded, ContractTrieNodeKey)
    check decoded.nodeHash == NodeHash.fromHex(nodeHash)
    check decoded.address == Address.fromHex(address)
    check decoded.path.isOddLength == isOddLength
    check decoded.path.packedNibbles == Nibbles.packedNibbles.init(packedNibbles)

  const contractCodeKeyEncoded = "000d836201318ec6899a67540690382780743280c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
  test "Encode/decode ContractCodeKey":
    let
      address = "000d836201318ec6899a67540690382780743280"
      codeHash = "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
      
      contractCodeKey = ContractCodeKey(address: Address.fromHex(address), codeHash: CodeHash.fromHex(codeHash))
      encoded = SSZ.encode(contractCodeKey)
    # echo ">>>", encoded.toHex()
    check encoded.toHex() == contractCodeKeyEncoded

    let decoded = SSZ.decode(encoded, ContractCodeKey)
    check decoded.address == Address.fromHex(address)
    check decoded.codeHash == CodeHash.fromHex(codeHash)

  const accountTrieNodeOfferEncoded = "24000000d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa308000000130000000500000000123456789abc04000000010203040506"
  test "Encode/decode AccountTrieNodeOffer":
    let
      nodeHash = "d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3"
      packedNibbles = @[NibblePair 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC]
      isOddLength = false
      key = Nibbles(packedNibbles: Nibbles.packedNibbles.init(packedNibbles), isOddLength: isOddLength)
      witnessNode = WitnessNode(@[byte 0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
      proof = Witness(@[witnessNode])

      accountTrieNodeOffer = AccountTrieNodeOffer(nodeHash: BlockHash.fromHex(nodeHash), proof: StateWitness(key: key, proof: proof))
      encoded = SSZ.encode(accountTrieNodeOffer)
    # echo ">>>", encoded.toHex()
    check encoded.toHex() == accountTrieNodeOfferEncoded

    let decoded = SSZ.decode(encoded, AccountTrieNodeOffer)
    check decoded.nodeHash == BlockHash.fromHex(nodeHash)
    check decoded.proof.key.isOddLength == isOddLength
    check decoded.proof.key.packedNibbles == Nibbles.packedNibbles.init(packedNibbles)
    check decoded.proof.proof == proof

  const accountTrieNodeRetrivalEncoded = "04000000010203040506"
  test "Encode/decode AccountTrieNodeRetrival":
    let
      witnessNode = WitnessNode(@[byte 0x01, 0x02, 0x03, 0x04, 0x05, 0x06])

      accountTrieNodeRetrival = AccountTrieNodeRetrival(node: witnessNode)
      encoded = SSZ.encode(accountTrieNodeRetrival)
    # echo ">>>", encoded.toHex()
    check encoded.toHex() == accountTrieNodeRetrivalEncoded

    let decoded = SSZ.decode(encoded, AccountTrieNodeRetrival)
    check decoded.node == witnessNode

  const contractTrieNodeOfferEncoded = "24000000d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa30c00000017000000220000000500000000123456789abc040000000102030405060708000000150000000500000000123456789abcdef104000000010203040506070809"
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
    check decoded.blockHash == BlockHash.fromHex(blockHash)
    check decoded.proof.key.isOddLength == false
    check decoded.proof.key.packedNibbles == Nibbles.packedNibbles.init(contractWitnessKeyPackedNibbles)
    check decoded.proof.proof == contractWitnessProof
    check decoded.proof.stateWitness.key.isOddLength == false
    check decoded.proof.stateWitness.key.packedNibbles == Nibbles.packedNibbles.init(stateWitnessKeyPackedNibbles)
    check decoded.proof.stateWitness.proof == stateWitnessProof

  const contractTrieNodeRetrivalEncoded = "04000000010203040506"
  test "Encode/decode ContractTrieNodeRetrival":
    let
      witnessNode = WitnessNode(@[byte 0x01, 0x02, 0x03, 0x04, 0x05, 0x06])

      contractTrieNodeRetrival = ContractTrieNodeRetrival(node: witnessNode)
      encoded = SSZ.encode(contractTrieNodeRetrival)
    # echo ">>>", encoded.toHex()
    check encoded.toHex() == contractTrieNodeRetrivalEncoded

    let decoded = SSZ.decode(encoded, ContractTrieNodeRetrival)
    check decoded.node == witnessNode

  const contractCodeOfferEncoded = "2800000036000000d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3010203040506070809a0a1a2a3a408000000130000000500000000123456789abc04000000010203040506"
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
    check decoded.code == ByteList.init(code)
    check decoded.blockHash == BlockHash.fromHex(blockHash)
    check decoded.accountProof.key.isOddLength == false
    check decoded.accountProof.key.packedNibbles == Nibbles.packedNibbles.init(@[NibblePair 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC])
    check decoded.accountProof.proof == accountProofWitness

  const contractCodeRetrivalEncoded = "04000000010203040506070809a0a1a2a3a4"
  test "Encode/decode ContractCodeRetrival":
    let
      code = @[byte 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4]

      contractCodeRetrival = ContractCodeRetrival(code: ByteList.init(code))
      encoded = SSZ.encode(contractCodeRetrival)
    # echo ">>>", encoded.toHex()
    check encoded.toHex() == contractCodeRetrivalEncoded

    let decoded = SSZ.decode(encoded, ContractCodeRetrival)
    check decoded.code == ByteList.init(code)


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
