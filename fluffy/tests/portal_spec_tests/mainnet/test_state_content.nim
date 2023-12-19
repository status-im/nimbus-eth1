# Fluffy
# Copyright (c) 2021-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  unittest2, stew/byteutils,
  ../../../network/state/state_content

# According to test vectors:
# https://github.com/ethereum/portal-network-specs/blob/master/content-keys-test-vectors.md#state-network-keys

suite "State ContentKey Encodings":
  # Common input
  const
    stateRoot = hexToByteArray[sizeof(Bytes32)](
      "0xd1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d")
    address = hexToByteArray[sizeof(Address)](
        "0x829bd824b016326a401d083b33d092293333a830")

  test "AccountTrieNode":
    # Input
    const
      nodeHash = NodeHash.fromHex(
        "0xb8be7903aee73b8f6a59cd44a1f52c62148e1f376c0dfa1f5f773a98666efc2b")
      path = ByteList.init(@[byte 1, 2, 0, 1])

    # Output
      contentKeyHex =
        "2044000000b8be7903aee73b8f6a59cd44a1f52c62148e1f376c0dfa1f5f773a98666efc2bd1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d01020001"
      contentId =
        "41237096982860596884042712109427867048220765019203857308279863638242761605893"
      # or
      contentIdHexBE =
        "5b2b5ea9a7384491010c1aa459a0f967dcf8b69988adbfe7e0bed513e9bb8305"

    let
      accountTrieNodeKey = AccountTrieNodeKey(
        path: path, nodeHash: nodeHash, stateRoot: stateRoot)
      contentKey = ContentKey(
        contentType: accountTrieNode, accountTrieNodeKey: accountTrieNodeKey)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex == contentKeyHex
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.accountTrieNodeKey == contentKey.accountTrieNodeKey

      toContentId(contentKey) == parse(contentId, StUint[256], 10)
      # In stint this does BE hex string
      toContentId(contentKey).toHex() == contentIdHexBE

  test "ContractStorageTrieNode":
    # Input
    const
      nodeHash = NodeHash.fromHex(
        "0x3e190b68719aecbcb28ed2271014dd25f2aa633184988eb414189ce0899cade5")
      path = ByteList.init(@[byte 1, 0, 15, 14, 12, 0])

    # Output
      contentKeyHex =
        "21829bd824b016326a401d083b33d092293333a830580000003e190b68719aecbcb28ed2271014dd25f2aa633184988eb414189ce0899cade5d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d01000f0e0c00"
      contentId =
        "43529358882110548041037387588279806363134301284609868141745095118932570363585"
      # or
      contentIdHexBE =
        "603cbe7902925ce359822378a4cb1b4b53e1bf19d003de2c26e55812d76956c1"

    let
      contractStorageTrieNodeKey = ContractStorageTrieNodeKey(
        address: address, path: path, nodeHash: nodeHash, stateRoot: stateRoot)
      contentKey = ContentKey(
        contentType: contractStorageTrieNode,
        contractStorageTrieNodeKey: contractStorageTrieNodeKey)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex == contentKeyHex
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.contractStorageTrieNodeKey ==
        contentKey.contractStorageTrieNodeKey

      toContentId(contentKey) == parse(contentId, StUint[256], 10)
      # In stint this does BE hex string
      toContentId(contentKey).toHex() == contentIdHexBE

  test "AccountTrieProof":
    # Output
    const
      contentKeyHex =
        "22829bd824b016326a401d083b33d092293333a830d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
      contentId =
        "45301550050471302973396879294932122279426162994178563319590607565171451545101"
      # or
      contentIdHexBE =
        "6427c4c8d42db15c2aca8dfc7dff7ce2c8c835441b566424fa3377dd031cc60d"

    let
      accountTrieProofKey = AccountTrieProofKey(
        address: address, stateRoot: stateRoot)
      contentKey = ContentKey(
        contentType: accountTrieProof,
        accountTrieProofKey: accountTrieProofKey)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex == contentKeyHex
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.accountTrieProofKey == contentKey.accountTrieProofKey

      toContentId(contentKey) == parse(contentId, StUint[256], 10)
      # In stint this does BE hex string
      toContentId(contentKey).toHex() == contentIdHexBE

  test "ContractStorageTrieProof":
    # Input
    const
      slot = 239304.stuint(256)

    # Output
      contentKeyHex =
        "23829bd824b016326a401d083b33d092293333a830c8a6030000000000000000000000000000000000000000000000000000000000d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
      contentId =
        "80413803151602881485894828440259195604313253842905231566803078625935967002376"
      # or
      contentIdHexBE =
        "b1c89984803cebd325303ba035f9c4ca0d0d91b2cbfef84d455e7a847ade1f08"

    let
      contractStorageTrieProofKey = ContractStorageTrieProofKey(
        address: address, slot: slot, stateRoot: stateRoot)
      contentKey = ContentKey(
        contentType: contractStorageTrieProof,
        contractStorageTrieProofKey: contractStorageTrieProofKey)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex == contentKeyHex
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.contractStorageTrieProofKey ==
        contentKey.contractStorageTrieProofKey

      toContentId(contentKey) == parse(contentId, StUint[256], 10)
      # In stint this does BE hex string
      toContentId(contentKey).toHex() == contentIdHexBE

  test "ContractBytecode":
    # Input
    const codeHash = CodeHash.fromHex(
      "0xd1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d")

    # Output
    const
      contentKeyHex =
        "24829bd824b016326a401d083b33d092293333a830d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
      contentId =
        "9243655320250466575533858917172702581481192615849913473767356296630272634800"
      # or
      contentIdHexBE =
        "146fb937afe42bcf11d25ad57d67734b9a7138677d59eeec3f402908f54dafb0"

    let
      contractBytecodeKey = ContractBytecodeKey(
        address: address, codeHash: codeHash)
      contentKey = ContentKey(
        contentType: contractBytecode,
        contractBytecodeKey: contractBytecodeKey)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex == contentKeyHex
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.contractBytecodeKey == contentKey.contractBytecodeKey

      toContentId(contentKey) == parse(contentId, StUint[256], 10)
      # In stint this does BE hex string
      toContentId(contentKey).toHex() == contentIdHexBE

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
