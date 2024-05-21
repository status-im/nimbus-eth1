# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest2,
  stew/byteutils,
  ../../network/state/state_content,
  ../../eth_data/yaml_utils

const testVectorDir = "./vendor/portal-spec-tests/tests/mainnet/state/serialization/"

suite "State Content Keys":
  test "Encode/decode AccountTrieNodeKey":
    const file = testVectorDir & "account_trie_node_key.yaml"

    type YamlAccountTrieNodeKey = object
      path: seq[byte]
      node_hash: string
      content_key: string
      content_id: string

    let
      testCase = YamlAccountTrieNodeKey.loadFromYaml(file).valueOr:
        raiseAssert "Cannot read test vector: " & error

      packedNibbles = packNibbles(testCase.path)
      nodeHash = NodeHash.fromHex(testCase.node_hash)
      contentKey = initAccountTrieNodeKey(packedNibbles, nodeHash)
      encoded = contentKey.encode()

    check:
      encoded.asSeq() == testCase.content_key.hexToSeqByte()
      encoded.toContentId().toBytesBE() == testCase.content_id.hexToSeqByte()

    let decoded = ContentKey.decode(encoded)
    check:
      decoded.isOk()
      decoded.value().contentType == accountTrieNode
      decoded.value().accountTrieNodeKey ==
        AccountTrieNodeKey(path: packedNibbles, nodeHash: nodeHash)

  test "Encode/decode ContractTrieNodeKey":
    const file = testVectorDir & "contract_storage_trie_node_key.yaml"

    type YamlContractStorageTrieNodeKey = object
      address: string
      path: seq[byte]
      node_hash: string
      content_key: string
      content_id: string

    let
      testCase = YamlContractStorageTrieNodeKey.loadFromYaml(file).valueOr:
        raiseAssert "Cannot read test vector: " & error

      packedNibbles = packNibbles(testCase.path)
      address = Address.fromHex(testCase.address)
      nodeHash = NodeHash.fromHex(testCase.node_hash)
      contentKey = initContractTrieNodeKey(address, packedNibbles, nodeHash)
      encoded = contentKey.encode()

    check:
      encoded.asSeq() == testCase.content_key.hexToSeqByte()
      encoded.toContentId().toBytesBE() == testCase.content_id.hexToSeqByte()

    let decoded = ContentKey.decode(encoded)
    check:
      decoded.isOk()
      decoded.value().contentType == contractTrieNode
      decoded.value().contractTrieNodeKey ==
        ContractTrieNodeKey(address: address, path: packedNibbles, nodeHash: nodeHash)

  test "Encode/decode ContractCodeKey":
    const file = testVectorDir & "contract_bytecode_key.yaml"

    type YamlContractBytecodeKey = object
      address: string
      code_hash: string
      content_key: string
      content_id: string

    let
      testCase = YamlContractBytecodeKey.loadFromYaml(file).valueOr:
        raiseAssert "Cannot read test vector: " & error

      address = Address.fromHex(testCase.address)
      codeHash = CodeHash.fromHex(testCase.code_hash)
      contentKey = initContractCodeKey(address, codeHash)
      encoded = contentKey.encode()

    check:
      encoded.asSeq() == testCase.content_key.hexToSeqByte()
      encoded.toContentId().toBytesBE() == testCase.content_id.hexToSeqByte()

    let decoded = ContentKey.decode(encoded)
    check:
      decoded.isOk()
      decoded.value().contentType == contractCode
      decoded.value().contractCodeKey.address == address
      decoded.value().contractCodeKey.codeHash == codeHash

  test "Invalid prefix - 0 value":
    let encoded = ByteList.init(@[byte 0x00])
    let decoded = ContentKey.decode(encoded)

    check decoded.isErr()

  test "Invalid prefix - before valid range":
    let encoded = ByteList.init(@[byte 0x01])
    let decoded = ContentKey.decode(encoded)

    check decoded.isErr()

  test "Invalid prefix - after valid range":
    let encoded = ByteList.init(@[byte 0x25])
    let decoded = ContentKey.decode(encoded)

    check decoded.isErr()

  test "Invalid key - empty input":
    let encoded = ByteList.init(@[])
    let decoded = ContentKey.decode(encoded)

    check decoded.isErr()
