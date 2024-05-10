# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/os,
  unittest2,
  stew/byteutils,
  eth/common,
  ../../network/state/state_content,
  ../../network/state/state_validation,
  ../../eth_data/yaml_utils

const testVectorDir = "./vendor/portal-spec-tests/tests/mainnet/state/validation/"

type YamlTrieNodeRecursiveGossipKV = ref object
  content_key: string
  content_value_offer: string
  content_value_retrieval: string

type YamlTrieNodeKV = object
  content_key: string
  content_value_offer: string
  content_value_retrieval: string
  recursive_gossip: YamlTrieNodeRecursiveGossipKV

type YamlTrieNodeKVs = seq[YamlTrieNodeKV]

type YamlContractBytecodeKV = object
  content_key: string
  content_value_offer: string
  content_value_retrieval: string

type YamlContractBytecodeKVs = seq[YamlContractBytecodeKV]

type YamlRecursiveGossipKV = object
  content_key: string
  content_value: string

type YamlRecursiveGossipKVs = seq[seq[YamlRecursiveGossipKV]]

suite "State Validation":
  # Retrieval validation tests

  test "Validate valid AccountTrieNodeRetrieval nodes":
    const file = testVectorDir / "account_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
      let contentValueRetrieval = SSZ.decode(
        testData.content_value_retrieval.hexToSeqByte(), AccountTrieNodeRetrieval
      )

      check:
        validateFetchedAccountTrieNode(
          contentKey.accountTrieNodeKey, contentValueRetrieval
        )

  test "Validate invalid AccountTrieNodeRetrieval nodes":
    const file = testVectorDir / "account_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
      var contentValueRetrieval = SSZ.decode(
        testData.content_value_retrieval.hexToSeqByte(), AccountTrieNodeRetrieval
      )

      contentValueRetrieval.node[^1] += 1 # Modify node hash

      check:
        not validateFetchedAccountTrieNode(
          contentKey.accountTrieNodeKey, contentValueRetrieval
        )

  test "Validate valid ContractTrieNodeRetrieval nodes":
    const file = testVectorDir / "contract_storage_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
      let contentValueRetrieval = SSZ.decode(
        testData.content_value_retrieval.hexToSeqByte(), ContractTrieNodeRetrieval
      )

      check:
        validateFetchedContractTrieNode(
          contentKey.contractTrieNodeKey, contentValueRetrieval
        )

  test "Validate invalid ContractTrieNodeRetrieval nodes":
    const file = testVectorDir / "contract_storage_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
      var contentValueRetrieval = SSZ.decode(
        testData.content_value_retrieval.hexToSeqByte(), ContractTrieNodeRetrieval
      )

      contentValueRetrieval.node[^1] += 1 # Modify node hash

      check:
        not validateFetchedContractTrieNode(
          contentKey.contractTrieNodeKey, contentValueRetrieval
        )

  test "Validate valid ContractCodeRetrieval nodes":
    const file = testVectorDir / "contract_bytecode.yaml"

    let testCase = YamlContractBytecodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
      let contentValueRetrieval = SSZ.decode(
        testData.content_value_retrieval.hexToSeqByte(), ContractCodeRetrieval
      )

      check:
        validateFetchedContractCode(contentKey.contractCodeKey, contentValueRetrieval)

  test "Validate invalid ContractCodeRetrieval nodes":
    const file = testVectorDir / "contract_bytecode.yaml"

    let testCase = YamlContractBytecodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
      var contentValueRetrieval = SSZ.decode(
        testData.content_value_retrieval.hexToSeqByte(), ContractCodeRetrieval
      )

      contentValueRetrieval.code[^1] += 1 # Modify node hash

      check:
        not validateFetchedContractCode(
          contentKey.contractCodeKey, contentValueRetrieval
        )

  # Account offer validation tests

  test "Validate valid AccountTrieNodeOffer nodes":
    const file = testVectorDir / "account_trie_node.yaml"
    const stateRoots = [
      "0x1ad7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61".hexToSeqByte(),
      "0x1ad7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61".hexToSeqByte(),
      "0xd7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544".hexToSeqByte(),
    ]

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      var stateRoot: KeccakHash
      copyMem(addr stateRoot, unsafeAddr stateRoots[i][0], 32)

      block:
        let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
        let contentValueOffer =
          SSZ.decode(testData.content_value_offer.hexToSeqByte(), AccountTrieNodeOffer)

        check:
          validateOfferedAccountTrieNode(
            stateRoot, contentKey.accountTrieNodeKey, contentValueOffer
          )

      if i == 1:
        continue # second test case only has root node and no recursive gossip

      let contentKey =
        decode(testData.recursive_gossip.content_key.hexToSeqByte().ByteList).get()
      let contentValueOffer = SSZ.decode(
        testData.recursive_gossip.content_value_offer.hexToSeqByte(),
        AccountTrieNodeOffer,
      )

      check:
        validateOfferedAccountTrieNode(
          stateRoot, contentKey.accountTrieNodeKey, contentValueOffer
        )

  test "Validate invalid AccountTrieNodeOffer nodes - bad state roots":
    const file = testVectorDir / "account_trie_node.yaml"
    const stateRoots = [
      "0xBAD7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61".hexToSeqByte(),
      "0xBAD7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61".hexToSeqByte(),
      "0xBAD8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544".hexToSeqByte(),
    ]

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      var stateRoot: KeccakHash
      copyMem(addr stateRoot, unsafeAddr stateRoots[i][0], 32)

      let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
      let contentValueOffer =
        SSZ.decode(testData.content_value_offer.hexToSeqByte(), AccountTrieNodeOffer)

      check:
        not validateOfferedAccountTrieNode(
          stateRoot, contentKey.accountTrieNodeKey, contentValueOffer
        )

  test "Validate invalid AccountTrieNodeOffer nodes - bad nodes":
    const file = testVectorDir / "account_trie_node.yaml"
    const stateRoots = [
      "0x1ad7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61".hexToSeqByte(),
      "0x1ad7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61".hexToSeqByte(),
      "0xd7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544".hexToSeqByte(),
    ]

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      var stateRoot: KeccakHash
      copyMem(addr stateRoot, unsafeAddr stateRoots[i][0], 32)

      let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
      var contentValueOffer =
        SSZ.decode(testData.content_value_offer.hexToSeqByte(), AccountTrieNodeOffer)

      contentValueOffer.proof[0][0] += 1.byte

      check:
        not validateOfferedAccountTrieNode(
          stateRoot, contentKey.accountTrieNodeKey, contentValueOffer
        )

    for i, testData in testCase:
      if i == 1:
        continue # second test case only has root node
      var stateRoot: KeccakHash
      copyMem(addr stateRoot, unsafeAddr stateRoots[i][0], 32)

      let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
      var contentValueOffer =
        SSZ.decode(testData.content_value_offer.hexToSeqByte(), AccountTrieNodeOffer)

      contentValueOffer.proof[^2][^2] += 1.byte

      check:
        not validateOfferedAccountTrieNode(
          stateRoot, contentKey.accountTrieNodeKey, contentValueOffer
        )

    for i, testData in testCase:
      var stateRoot: KeccakHash
      copyMem(addr stateRoot, unsafeAddr stateRoots[i][0], 32)

      let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
      var contentValueOffer =
        SSZ.decode(testData.content_value_offer.hexToSeqByte(), AccountTrieNodeOffer)

      contentValueOffer.proof[^1][^1] += 1.byte

      check:
        not validateOfferedAccountTrieNode(
          stateRoot, contentKey.accountTrieNodeKey, contentValueOffer
        )

  # Contract storage offer validation tests

  test "Validate valid ContractTrieNodeOffer nodes":
    const file = testVectorDir / "contract_storage_trie_node.yaml"
    const stateRoots = [
      "0x1ad7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61".hexToSeqByte(),
      "0x1ad7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61".hexToSeqByte(),
    ]

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      var stateRoot: KeccakHash
      copyMem(addr stateRoot, unsafeAddr stateRoots[i][0], 32)

      block:
        let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
        let contentValueOffer =
          SSZ.decode(testData.content_value_offer.hexToSeqByte(), ContractTrieNodeOffer)

        check:
          validateOfferedContractTrieNode(
            stateRoot, contentKey.contractTrieNodeKey, contentValueOffer
          )

      if i == 1:
        continue # second test case has no recursive gossip

      let contentKey =
        decode(testData.recursive_gossip.content_key.hexToSeqByte().ByteList).get()
      let contentValueOffer = SSZ.decode(
        testData.recursive_gossip.content_value_offer.hexToSeqByte(),
        ContractTrieNodeOffer,
      )

      check:
        validateOfferedContractTrieNode(
          stateRoot, contentKey.contractTrieNodeKey, contentValueOffer
        )

  test "Validate invalid ContractTrieNodeOffer nodes - bad state roots":
    const file = testVectorDir / "contract_storage_trie_node.yaml"
    const stateRoots = [
      "0xBAD7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61".hexToSeqByte(),
      "0xBAD7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61".hexToSeqByte(),
    ]

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      var stateRoot: KeccakHash
      copyMem(addr stateRoot, unsafeAddr stateRoots[i][0], 32)

      let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
      let contentValueOffer =
        SSZ.decode(testData.content_value_offer.hexToSeqByte(), ContractTrieNodeOffer)

      check:
        not validateOfferedContractTrieNode(
          stateRoot, contentKey.contractTrieNodeKey, contentValueOffer
        )

  test "Validate invalid ContractTrieNodeOffer nodes - bad nodes":
    const file = testVectorDir / "contract_storage_trie_node.yaml"
    const stateRoots = [
      "0x1ad7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61".hexToSeqByte(),
      "0x1ad7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61".hexToSeqByte(),
    ]

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      var stateRoot: KeccakHash
      copyMem(addr stateRoot, unsafeAddr stateRoots[i][0], 32)

      block:
        let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
        var contentValueOffer =
          SSZ.decode(testData.content_value_offer.hexToSeqByte(), ContractTrieNodeOffer)

        contentValueOffer.accountProof[0][0] += 1.byte

        check:
          not validateOfferedContractTrieNode(
            stateRoot, contentKey.contractTrieNodeKey, contentValueOffer
          )

      block:
        let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
        var contentValueOffer =
          SSZ.decode(testData.content_value_offer.hexToSeqByte(), ContractTrieNodeOffer)

        contentValueOffer.storageProof[0][0] += 1.byte

        check:
          not validateOfferedContractTrieNode(
            stateRoot, contentKey.contractTrieNodeKey, contentValueOffer
          )

      block:
        let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
        var contentValueOffer =
          SSZ.decode(testData.content_value_offer.hexToSeqByte(), ContractTrieNodeOffer)

        contentValueOffer.accountProof[^1][^1] += 1.byte

        check:
          not validateOfferedContractTrieNode(
            stateRoot, contentKey.contractTrieNodeKey, contentValueOffer
          )

      block:
        let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
        var contentValueOffer =
          SSZ.decode(testData.content_value_offer.hexToSeqByte(), ContractTrieNodeOffer)

        contentValueOffer.storageProof[^1][^1] += 1.byte

        check:
          not validateOfferedContractTrieNode(
            stateRoot, contentKey.contractTrieNodeKey, contentValueOffer
          )

      block:
        let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
        var contentValueOffer =
          SSZ.decode(testData.content_value_offer.hexToSeqByte(), ContractTrieNodeOffer)

        contentValueOffer.accountProof[^2][^2] += 1.byte

        check:
          not validateOfferedContractTrieNode(
            stateRoot, contentKey.contractTrieNodeKey, contentValueOffer
          )

  # Contract bytecode offer validation tests

  test "Validate valid ContractCodeOffer nodes":
    const file = testVectorDir / "contract_bytecode.yaml"
    const stateRoots = [
      "0x1ad7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61".hexToSeqByte()
    ]

    let testCase = YamlContractBytecodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      var stateRoot: KeccakHash
      copyMem(addr stateRoot, unsafeAddr stateRoots[i][0], 32)

      let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
      let contentValueOffer =
        SSZ.decode(testData.content_value_offer.hexToSeqByte(), ContractCodeOffer)

      check:
        validateOfferedContractCode(
          stateRoot, contentKey.contractCodeKey, contentValueOffer
        )

  test "Validate invalid ContractCodeOffer nodes - bad state root":
    const file = testVectorDir / "contract_bytecode.yaml"
    const stateRoots = [
      "0xBAD7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61".hexToSeqByte()
    ]

    let testCase = YamlContractBytecodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      var stateRoot: KeccakHash
      copyMem(addr stateRoot, unsafeAddr stateRoots[i][0], 32)

      let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
      let contentValueOffer =
        SSZ.decode(testData.content_value_offer.hexToSeqByte(), ContractCodeOffer)

      check:
        not validateOfferedContractCode(
          stateRoot, contentKey.contractCodeKey, contentValueOffer
        )

  test "Validate invalid ContractCodeOffer nodes - bad nodes and bytecode":
    const file = testVectorDir / "contract_bytecode.yaml"
    const stateRoots = [
      "0x1ad7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61".hexToSeqByte()
    ]

    let testCase = YamlContractBytecodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      var stateRoot: KeccakHash
      copyMem(addr stateRoot, unsafeAddr stateRoots[i][0], 32)

      block:
        let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
        var contentValueOffer =
          SSZ.decode(testData.content_value_offer.hexToSeqByte(), ContractCodeOffer)

        contentValueOffer.accountProof[0][0] += 1.byte

        check:
          not validateOfferedContractCode(
            stateRoot, contentKey.contractCodeKey, contentValueOffer
          )

      block:
        let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
        var contentValueOffer =
          SSZ.decode(testData.content_value_offer.hexToSeqByte(), ContractCodeOffer)

        contentValueOffer.code[0] += 1.byte

        check:
          not validateOfferedContractCode(
            stateRoot, contentKey.contractCodeKey, contentValueOffer
          )

      block:
        let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
        var contentValueOffer =
          SSZ.decode(testData.content_value_offer.hexToSeqByte(), ContractCodeOffer)

        contentValueOffer.accountProof[^1][^1] += 1.byte

        check:
          not validateOfferedContractCode(
            stateRoot, contentKey.contractCodeKey, contentValueOffer
          )

      block:
        let contentKey = decode(testData.content_key.hexToSeqByte().ByteList).get()
        var contentValueOffer =
          SSZ.decode(testData.content_value_offer.hexToSeqByte(), ContractCodeOffer)

        contentValueOffer.code[^1] += 1.byte

        check:
          not validateOfferedContractCode(
            stateRoot, contentKey.contractCodeKey, contentValueOffer
          )

  # Recursive gossip offer validation tests

test "Validate valid AccountTrieNodeOffer nodes":
  const file = testVectorDir / "recursive_gossip.yaml"
  const stateRoots = [
    "0x1ad7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61".hexToSeqByte(),
    "0x1ad7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61".hexToSeqByte(),
    "0xd7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544".hexToSeqByte(),
  ]

  let testCase = YamlRecursiveGossipKVs.loadFromYaml(file).valueOr:
    raiseAssert "Cannot read test vector: " & error

  for i, testData in testCase:
    var stateRoot: KeccakHash
    copyMem(addr stateRoot, unsafeAddr stateRoots[i][0], 32)

    for j, kv in testData:
      let contentKey = decode(kv.content_key.hexToSeqByte().ByteList).get()
      let contentValueOffer =
        SSZ.decode(kv.content_value.hexToSeqByte(), AccountTrieNodeOffer)

      check:
        validateOfferedAccountTrieNode(
          stateRoot, contentKey.accountTrieNodeKey, contentValueOffer
        )
