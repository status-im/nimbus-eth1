# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[os, strutils],
  results,
  unittest2,
  stew/byteutils,
  eth/common,
  ../../common/common_utils,
  ../../network/state/[state_content, state_validation],
  ./state_test_helpers

suite "State Validation - Test Vectors":
  # Retrieval validation tests

  test "Validate valid AccountTrieNodeRetrieval nodes":
    const file = testVectorDir / "account_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let contentKey =
        ContentKey.decode(testData.content_key.hexToSeqByte().ContentKeyByteList).get()
      let contentValueRetrieval = AccountTrieNodeRetrieval
        .decode(testData.content_value_retrieval.hexToSeqByte())
        .get()

      check:
        validateRetrieval(contentKey.accountTrieNodeKey, contentValueRetrieval).isOk()

  test "Validate invalid AccountTrieNodeRetrieval nodes":
    const file = testVectorDir / "account_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let contentKey =
        ContentKey.decode(testData.content_key.hexToSeqByte().ContentKeyByteList).get()
      var contentValueRetrieval = AccountTrieNodeRetrieval
        .decode(testData.content_value_retrieval.hexToSeqByte())
        .get()

      contentValueRetrieval.node[^1] += 1 # Modify node hash

      let res = validateRetrieval(contentKey.accountTrieNodeKey, contentValueRetrieval)
      check:
        res.isErr()
        res.error() == "hash of account trie node doesn't match the expected node hash"

  test "Validate valid ContractTrieNodeRetrieval nodes":
    const file = testVectorDir / "contract_storage_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let contentKey =
        ContentKey.decode(testData.content_key.hexToSeqByte().ContentKeyByteList).get()
      let contentValueRetrieval = ContractTrieNodeRetrieval
        .decode(testData.content_value_retrieval.hexToSeqByte())
        .get()

      check:
        validateRetrieval(contentKey.contractTrieNodeKey, contentValueRetrieval).isOk()

  test "Validate invalid ContractTrieNodeRetrieval nodes":
    const file = testVectorDir / "contract_storage_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let contentKey =
        ContentKey.decode(testData.content_key.hexToSeqByte().ContentKeyByteList).get()
      var contentValueRetrieval = ContractTrieNodeRetrieval
        .decode(testData.content_value_retrieval.hexToSeqByte())
        .get()

      contentValueRetrieval.node[^1] += 1 # Modify node hash

      let res = validateRetrieval(contentKey.contractTrieNodeKey, contentValueRetrieval)
      check:
        res.isErr()
        res.error() == "hash of contract trie node doesn't match the expected node hash"

  test "Validate valid ContractCodeRetrieval nodes":
    const file = testVectorDir / "contract_bytecode.yaml"

    let testCase = YamlContractBytecodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let contentKey =
        ContentKey.decode(testData.content_key.hexToSeqByte().ContentKeyByteList).get()
      let contentValueRetrieval = ContractCodeRetrieval
        .decode(testData.content_value_retrieval.hexToSeqByte())
        .get()

      check:
        validateRetrieval(contentKey.contractCodeKey, contentValueRetrieval).isOk()

  test "Validate invalid ContractCodeRetrieval nodes":
    const file = testVectorDir / "contract_bytecode.yaml"

    let testCase = YamlContractBytecodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for testData in testCase:
      let contentKey =
        ContentKey.decode(testData.content_key.hexToSeqByte().ContentKeyByteList).get()
      var contentValueRetrieval = ContractCodeRetrieval
        .decode(testData.content_value_retrieval.hexToSeqByte())
        .get()

      contentValueRetrieval.code[^1] += 1 # Modify node hash

      let res = validateRetrieval(contentKey.contractCodeKey, contentValueRetrieval)
      check:
        res.isErr()
        res.error() == "hash of bytecode doesn't match the expected code hash"

  # Account offer validation tests

  test "Validate valid AccountTrieNodeOffer nodes":
    const file = testVectorDir / "account_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      var stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())

      block:
        let contentKey = ContentKey
          .decode(testData.content_key.hexToSeqByte().ContentKeyByteList)
          .get()
        let contentValueOffer =
          AccountTrieNodeOffer.decode(testData.content_value_offer.hexToSeqByte()).get()

        check:
          validateOffer(
            Opt.some(stateRoot), contentKey.accountTrieNodeKey, contentValueOffer
          )
          .isOk()

      if i == 1:
        continue # second test case only has root node and no recursive gossip

      let contentKey = ContentKey
        .decode(testData.recursive_gossip.content_key.hexToSeqByte().ContentKeyByteList)
        .get()
      let contentValueOffer = AccountTrieNodeOffer
        .decode(testData.recursive_gossip.content_value_offer.hexToSeqByte())
        .get()

      check:
        validateOffer(
          Opt.some(stateRoot), contentKey.accountTrieNodeKey, contentValueOffer
        )
        .isOk()

  test "Validate invalid AccountTrieNodeOffer nodes - bad state roots":
    const file = testVectorDir / "account_trie_node.yaml"
    const stateRoots = [
      "0xBAD7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61",
      "0xBAD7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61",
      "0xBAD8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544",
    ]

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      var stateRoot = KeccakHash.fromBytes(stateRoots[i].hexToSeqByte())

      let contentKey =
        ContentKey.decode(testData.content_key.hexToSeqByte().ContentKeyByteList).get()
      let contentValueOffer =
        AccountTrieNodeOffer.decode(testData.content_value_offer.hexToSeqByte()).get()

      let res = validateOffer(
        Opt.some(stateRoot), contentKey.accountTrieNodeKey, contentValueOffer
      )
      check:
        res.isErr()
        res.error() == "hash of proof root node doesn't match the expected root hash"

  test "Validate invalid AccountTrieNodeOffer nodes - bad nodes":
    const file = testVectorDir / "account_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      var stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())

      let contentKey =
        ContentKey.decode(testData.content_key.hexToSeqByte().ContentKeyByteList).get()
      var contentValueOffer =
        AccountTrieNodeOffer.decode(testData.content_value_offer.hexToSeqByte()).get()

      contentValueOffer.proof[0][0] += 1.byte

      let res = validateOffer(
        Opt.some(stateRoot), contentKey.accountTrieNodeKey, contentValueOffer
      )
      check:
        res.isErr()
        res.error() == "hash of proof root node doesn't match the expected root hash"

    for i, testData in testCase:
      if i == 1:
        continue # second test case only has root node
      var stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())

      let contentKey =
        ContentKey.decode(testData.content_key.hexToSeqByte().ContentKeyByteList).get()
      var contentValueOffer =
        AccountTrieNodeOffer.decode(testData.content_value_offer.hexToSeqByte()).get()

      contentValueOffer.proof[^2][^2] += 1.byte

      let res = validateOffer(
        Opt.some(stateRoot), contentKey.accountTrieNodeKey, contentValueOffer
      )
      check:
        res.isErr()
        "hash of next node doesn't match the expected" in res.error()

    for i, testData in testCase:
      var stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())

      let contentKey =
        ContentKey.decode(testData.content_key.hexToSeqByte().ContentKeyByteList).get()
      var contentValueOffer =
        AccountTrieNodeOffer.decode(testData.content_value_offer.hexToSeqByte()).get()

      contentValueOffer.proof[^1][^1] += 1.byte

      let res = validateOffer(
        Opt.some(stateRoot), contentKey.accountTrieNodeKey, contentValueOffer
      )
      check:
        res.isErr()

  # Contract storage offer validation tests

  test "Validate valid ContractTrieNodeOffer nodes":
    const file = testVectorDir / "contract_storage_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      var stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())

      block:
        let contentKey = ContentKey
          .decode(testData.content_key.hexToSeqByte().ContentKeyByteList)
          .get()
        let contentValueOffer = ContractTrieNodeOffer
          .decode(testData.content_value_offer.hexToSeqByte())
          .get()

        check:
          validateOffer(
            Opt.some(stateRoot), contentKey.contractTrieNodeKey, contentValueOffer
          )
          .isOk()

      if i == 1:
        continue # second test case has no recursive gossip

      let contentKey = ContentKey
        .decode(testData.recursive_gossip.content_key.hexToSeqByte().ContentKeyByteList)
        .get()
      let contentValueOffer = ContractTrieNodeOffer
        .decode(testData.recursive_gossip.content_value_offer.hexToSeqByte())
        .get()

      check:
        validateOffer(
          Opt.some(stateRoot), contentKey.contractTrieNodeKey, contentValueOffer
        )
        .isOk()

  test "Validate invalid ContractTrieNodeOffer nodes - bad state roots":
    const file = testVectorDir / "contract_storage_trie_node.yaml"
    const stateRoots = [
      "0xBAD7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61",
      "0xBAD7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61",
    ]

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      var stateRoot = KeccakHash.fromBytes(stateRoots[i].hexToSeqByte())

      let contentKey =
        ContentKey.decode(testData.content_key.hexToSeqByte().ContentKeyByteList).get()
      let contentValueOffer =
        ContractTrieNodeOffer.decode(testData.content_value_offer.hexToSeqByte()).get()

      let res = validateOffer(
        Opt.some(stateRoot), contentKey.contractTrieNodeKey, contentValueOffer
      )
      check:
        res.isErr()
        res.error() == "hash of proof root node doesn't match the expected root hash"

  test "Validate invalid ContractTrieNodeOffer nodes - bad nodes":
    const file = testVectorDir / "contract_storage_trie_node.yaml"

    let testCase = YamlTrieNodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      var stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())

      block:
        let contentKey = ContentKey
          .decode(testData.content_key.hexToSeqByte().ContentKeyByteList)
          .get()
        var contentValueOffer = ContractTrieNodeOffer
          .decode(testData.content_value_offer.hexToSeqByte())
          .get()

        contentValueOffer.accountProof[0][0] += 1.byte

        let res = validateOffer(
          Opt.some(stateRoot), contentKey.contractTrieNodeKey, contentValueOffer
        )
        check:
          res.isErr()
          res.error() == "hash of proof root node doesn't match the expected root hash"

      block:
        let contentKey = ContentKey
          .decode(testData.content_key.hexToSeqByte().ContentKeyByteList)
          .get()
        var contentValueOffer = ContractTrieNodeOffer
          .decode(testData.content_value_offer.hexToSeqByte())
          .get()

        contentValueOffer.storageProof[0][0] += 1.byte

        let res = validateOffer(
          Opt.some(stateRoot), contentKey.contractTrieNodeKey, contentValueOffer
        )
        check:
          res.isErr()
          res.error() == "hash of proof root node doesn't match the expected root hash"

      block:
        let contentKey = ContentKey
          .decode(testData.content_key.hexToSeqByte().ContentKeyByteList)
          .get()
        var contentValueOffer = ContractTrieNodeOffer
          .decode(testData.content_value_offer.hexToSeqByte())
          .get()

        contentValueOffer.accountProof[^1][^1] += 1.byte

        check:
          validateOffer(
            Opt.some(stateRoot), contentKey.contractTrieNodeKey, contentValueOffer
          )
          .isErr()

      block:
        let contentKey = ContentKey
          .decode(testData.content_key.hexToSeqByte().ContentKeyByteList)
          .get()
        var contentValueOffer = ContractTrieNodeOffer
          .decode(testData.content_value_offer.hexToSeqByte())
          .get()

        contentValueOffer.storageProof[^1][^1] += 1.byte

        check:
          validateOffer(
            Opt.some(stateRoot), contentKey.contractTrieNodeKey, contentValueOffer
          )
          .isErr()

      block:
        let contentKey = ContentKey
          .decode(testData.content_key.hexToSeqByte().ContentKeyByteList)
          .get()
        var contentValueOffer = ContractTrieNodeOffer
          .decode(testData.content_value_offer.hexToSeqByte())
          .get()

        contentValueOffer.accountProof[^2][^2] += 1.byte

        check:
          validateOffer(
            Opt.some(stateRoot), contentKey.contractTrieNodeKey, contentValueOffer
          )
          .isErr()

  # Contract bytecode offer validation tests

  test "Validate valid ContractCodeOffer nodes":
    const file = testVectorDir / "contract_bytecode.yaml"

    let testCase = YamlContractBytecodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      var stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())

      let contentKey =
        ContentKey.decode(testData.content_key.hexToSeqByte().ContentKeyByteList).get()
      let contentValueOffer =
        ContractCodeOffer.decode(testData.content_value_offer.hexToSeqByte()).get()

      check:
        validateOffer(
          Opt.some(stateRoot), contentKey.contractCodeKey, contentValueOffer
        )
        .isOk()

  test "Validate invalid ContractCodeOffer nodes - bad state root":
    const file = testVectorDir / "contract_bytecode.yaml"
    const stateRoots =
      ["0xBAD7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61"]

    let testCase = YamlContractBytecodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      var stateRoot = KeccakHash.fromBytes(stateRoots[i].hexToSeqByte())

      let contentKey =
        ContentKey.decode(testData.content_key.hexToSeqByte().ContentKeyByteList).get()
      let contentValueOffer =
        ContractCodeOffer.decode(testData.content_value_offer.hexToSeqByte()).get()

      let res = validateOffer(
        Opt.some(stateRoot), contentKey.contractCodeKey, contentValueOffer
      )
      check:
        res.isErr()
        res.error() == "hash of proof root node doesn't match the expected root hash"

  test "Validate invalid ContractCodeOffer nodes - bad nodes and bytecode":
    const file = testVectorDir / "contract_bytecode.yaml"

    let testCase = YamlContractBytecodeKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      var stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())

      block:
        let contentKey = ContentKey
          .decode(testData.content_key.hexToSeqByte().ContentKeyByteList)
          .get()
        var contentValueOffer =
          ContractCodeOffer.decode(testData.content_value_offer.hexToSeqByte()).get()

        contentValueOffer.accountProof[0][0] += 1.byte

        let res = validateOffer(
          Opt.some(stateRoot), contentKey.contractCodeKey, contentValueOffer
        )
        check:
          res.isErr()
          res.error() == "hash of proof root node doesn't match the expected root hash"

      block:
        let contentKey = ContentKey
          .decode(testData.content_key.hexToSeqByte().ContentKeyByteList)
          .get()
        var contentValueOffer =
          ContractCodeOffer.decode(testData.content_value_offer.hexToSeqByte()).get()

        contentValueOffer.code[0] += 1.byte

        let res = validateOffer(
          Opt.some(stateRoot), contentKey.contractCodeKey, contentValueOffer
        )
        check:
          res.isErr()
          res.error() ==
            "hash of bytecode doesn't match the code hash in the account proof"

      block:
        let contentKey = ContentKey
          .decode(testData.content_key.hexToSeqByte().ContentKeyByteList)
          .get()
        var contentValueOffer =
          ContractCodeOffer.decode(testData.content_value_offer.hexToSeqByte()).get()

        contentValueOffer.accountProof[^1][^1] += 1.byte

        check:
          validateOffer(
            Opt.some(stateRoot), contentKey.contractCodeKey, contentValueOffer
          )
          .isErr()

      block:
        let contentKey = ContentKey
          .decode(testData.content_key.hexToSeqByte().ContentKeyByteList)
          .get()
        var contentValueOffer =
          ContractCodeOffer.decode(testData.content_value_offer.hexToSeqByte()).get()

        contentValueOffer.code[^1] += 1.byte

        let res = validateOffer(
          Opt.some(stateRoot), contentKey.contractCodeKey, contentValueOffer
        )
        check:
          res.isErr()
          res.error() ==
            "hash of bytecode doesn't match the code hash in the account proof"

  # Recursive gossip offer validation tests

  test "Validate valid AccountTrieNodeOffer recursive gossip nodes":
    const file = testVectorDir / "recursive_gossip.yaml"
    const stateRoots = [
      "0x1ad7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61",
      "0x1ad7b80af0c28bc1489513346d2706885be90abb07f23ca28e50482adb392d61",
      "0xd7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544",
    ]

    let testCase = YamlRecursiveGossipKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      if i == 1:
        continue

      var stateRoot = KeccakHash.fromBytes(stateRoots[i].hexToSeqByte())

      for kv in testData.recursive_gossip:
        let contentKey =
          ContentKey.decode(kv.content_key.hexToSeqByte().ContentKeyByteList).get()
        let contentValueOffer =
          AccountTrieNodeOffer.decode(kv.content_value.hexToSeqByte()).get()

        check:
          validateOffer(
            Opt.some(stateRoot), contentKey.accountTrieNodeKey, contentValueOffer
          )
          .isOk()

  test "Validate valid ContractTrieNodeOffer recursive gossip nodes":
    const file = testVectorDir / "recursive_gossip.yaml"

    let testCase = YamlRecursiveGossipKVs.loadFromYaml(file).valueOr:
      raiseAssert "Cannot read test vector: " & error

    for i, testData in testCase:
      if i != 1:
        continue

      var stateRoot = KeccakHash.fromBytes(testData.state_root.hexToSeqByte())

      for kv in testData.recursive_gossip:
        let contentKey =
          ContentKey.decode(kv.content_key.hexToSeqByte().ContentKeyByteList).get()
        let contentValueOffer =
          ContractTrieNodeOffer.decode(kv.content_value.hexToSeqByte()).get()

        check:
          validateOffer(
            Opt.some(stateRoot), contentKey.contractTrieNodeKey, contentValueOffer
          )
          .isOk()
