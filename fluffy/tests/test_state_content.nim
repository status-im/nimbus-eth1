# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  unittest2, stew/byteutils,
  ../network/state/state_content

# According to test vectors:
# TODO: Add link once test vectors are merged

suite "State ContentKey Encodings":
  const
    stateRoot = hexToByteArray[sizeof(Bytes32)](
      "0xd1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d")
    address = hexToByteArray[sizeof(Address)](
        "0x829bd824b016326a401d083b33d092293333a830")

  test "AccountTrieNode":
    var nodeHash: NodeHash
    nodeHash.data = hexToByteArray[sizeof(NodeHash)](
      "0xb8be7903aee73b8f6a59cd44a1f52c62148e1f376c0dfa1f5f773a98666efc2b")
    let path = ByteList.init(@[byte 1, 2, 0, 1])

    let
      accountTrieNodeKey = AccountTrieNodeKey(
        path: path, nodeHash: nodeHash, stateRoot: stateRoot)
      contentKey = ContentKey(
        contentType: accountTrieNode, accountTrieNodeKey: accountTrieNodeKey)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex ==
      "0044000000b8be7903aee73b8f6a59cd44a1f52c62148e1f376c0dfa1f5f773a98666efc2bd1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d01020001"
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.accountTrieNodeKey == contentKey.accountTrieNodeKey

      toContentId(contentKey).toHex() ==
        "5b2b5ea9a7384491010c1aa459a0f967dcf8b69988adbfe7e0bed513e9bb8305"

  test "ContractStorageTrieNode":
    var nodeHash: NodeHash
    nodeHash.data = hexToByteArray[sizeof(NodeHash)](
      "0x3e190b68719aecbcb28ed2271014dd25f2aa633184988eb414189ce0899cade5")
    let path = ByteList.init(@[byte 1, 0, 15, 14, 12, 0])

    let
      contractStorageTrieNodeKey = ContractStorageTrieNodeKey(
        address: address, path: path, nodeHash: nodeHash, stateRoot: stateRoot)
      contentKey = ContentKey(
        contentType: contractStorageTrieNode,
        contractStorageTrieNodeKey: contractStorageTrieNodeKey)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex ==
      "01829bd824b016326a401d083b33d092293333a830580000003e190b68719aecbcb28ed2271014dd25f2aa633184988eb414189ce0899cade5d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d01000f0e0c00"
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.contractStorageTrieNodeKey ==
        contentKey.contractStorageTrieNodeKey

      toContentId(contentKey).toHex() ==
        "603cbe7902925ce359822378a4cb1b4b53e1bf19d003de2c26e55812d76956c1"

  test "AccountTrieProof":
    let
      accountTrieProofKey = AccountTrieProofKey(
        address: address, stateRoot: stateRoot)
      contentKey = ContentKey(
        contentType: accountTrieProof,
        accountTrieProofKey: accountTrieProofKey)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex ==
      "02829bd824b016326a401d083b33d092293333a830d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.accountTrieProofKey == contentKey.accountTrieProofKey

      toContentId(contentKey).toHex() ==
        "6427c4c8d42db15c2aca8dfc7dff7ce2c8c835441b566424fa3377dd031cc60d"

  test "ContractStorageTrieProof":
    let slot = 239304.stuint(256)

    let
      contractStorageTrieProofKey = ContractStorageTrieProofKey(
        address: address, slot: slot, stateRoot: stateRoot)
      contentKey = ContentKey(
        contentType: contractStorageTrieProof,
        contractStorageTrieProofKey: contractStorageTrieProofKey)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex ==
      "03829bd824b016326a401d083b33d092293333a830c8a6030000000000000000000000000000000000000000000000000000000000d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.contractStorageTrieProofKey ==
        contentKey.contractStorageTrieProofKey

      toContentId(contentKey).toHex() ==
        "ce5a3a6bc958561da0015d92f2f6b4f5a2cf6a4ae3f6a75c97f05e9e2a6f4387"

  test "ContractBytecode":
    var codeHash: CodeHash
    codeHash.data = hexToByteArray[sizeof(CodeHash)](
      "0xd1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d")

    let
      contractBytecodeKey = ContractBytecodeKey(
        address: address, codeHash: codeHash)
      contentKey = ContentKey(
        contentType: contractBytecode,
        contractBytecodeKey: contractBytecodeKey)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex ==
      "04829bd824b016326a401d083b33d092293333a830d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.contractBytecodeKey == contentKey.contractBytecodeKey

      toContentId(contentKey).toHex() ==
        "146fb937afe42bcf11d25ad57d67734b9a7138677d59eeec3f402908f54dafb0"
