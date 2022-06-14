# Nimbus
# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  unittest2, stew/byteutils, stint,
  ../network/history/history_content

# According to test vectors:
# https://github.com/ethereum/portal-network-specs/blob/master/content-keys-test-vectors.md#history-network-keys

suite "History ContentKey Encodings":
  test "BlockHeader":
    # Input
    var blockHash: BlockHash
    blockHash.data = hexToByteArray[sizeof(BlockHash)](
      "0xd1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d")

    # Output
    const
      contentKeyHex =
        "000f00d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
      contentId =
        "15025167517633317571792618561170587584740338038067807801482118109695980329625"
      # or
      contentIdHexBE =
        "2137f185b713a60dd1190e650d01227b4f94ecddc9c95478e2c591c40557da99"

    let contentKey = ContentKey(
      contentType: blockHeader,
      blockHeaderKey: BlockKey(chainId: 15'u16, blockHash: blockHash))

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex == contentKeyHex
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.blockHeaderKey == contentKey.blockHeaderKey

      toContentId(contentKey) == parse(contentId, Stuint[256], 10)
      # In stint this does BE hex string
      toContentId(contentKey).toHex() == contentIdHexBE

  test "BlockBody":
    # Input
    var blockHash: BlockHash
    blockHash.data = hexToByteArray[sizeof(BlockHash)](
      "0xd1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d")

    # Output
    const
      contentKeyHex =
        "011400d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
      contentId =
        "12834862124958403129911294156243112356210437741210740000860318140844473844426"
      # or
      contentIdHexBE =
        "1c6046475f0772132774ab549173ca8487bea031ce539cad8e990c08df5802ca"

    let contentKey = ContentKey(
      contentType: blockBody,
      blockBodyKey: BlockKey(chainId: 20'u16, blockHash: blockHash))

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex == contentKeyHex
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.blockBodyKey == contentKey.blockBodyKey

      toContentId(contentKey) == parse(contentId, Stuint[256], 10)
      # In stint this does BE hex string
      toContentId(contentKey).toHex() == contentIdHexBE

  test "Receipts":
    var blockHash: BlockHash
    blockHash.data = hexToByteArray[sizeof(BlockHash)](
      "0xd1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d")

    # Output
    const
      contentKeyHex =
        "020400d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
      contentId =
        "76995449220721979583200368506411933662679656077191192504502358532083948020658"
      # or
      contentIdHexBE =
        "aa39e1423e92f5a667ace5b79c2c98adbfd79c055d891d0b9c49c40f816563b2"

    let contentKey = ContentKey(
      contentType: receipts,
      receiptsKey: BlockKey(chainId: 4'u16, blockHash: blockHash))

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex == contentKeyHex
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.receiptsKey == contentKey.receiptsKey

      toContentId(contentKey) == parse(contentId, Stuint[256], 10)
      # In stint this does BE hex string
      toContentId(contentKey).toHex() == contentIdHexBE

  test "Epoch Accumulator":
    var epochHash: Digest
    epochHash.data = hexToByteArray[sizeof(Digest)](
      "0xe242814b90ed3950e13aac7e56ce116540c71b41d1516605aada26c6c07cc491")

    const
      contentKeyHex =
        "03e242814b90ed3950e13aac7e56ce116540c71b41d1516605aada26c6c07cc491"
      contentId =
        "72232402989179419196382321898161638871438419016077939952896528930608027961710"
      # or
      contentIdHexBE =
        "9fb2175e76c6989e0fdac3ee10c40d2a81eb176af32e1c16193e3904fe56896e"

    let contentKey = ContentKey(
      contentType: epochAccumulator,
      epochAccumulatorKey: EpochAccumulatorKey(epochHash: epochHash))

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex == contentKeyHex
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.epochAccumulatorKey == contentKey.epochAccumulatorKey

      toContentId(contentKey) == parse(contentId, Stuint[256], 10)
      # In stint this does BE hex string
      toContentId(contentKey).toHex() == contentIdHexBE

  test "Master Accumulator - Latest":
    var accumulatorHash: Digest
    accumulatorHash.data = hexToByteArray[sizeof(Digest)](
      "0x88cce8439ebc0c1d007177ffb6831c15c07b4361984cc52235b6fd728434f0c7")

    const
      contentKeyHex =
        "0400"
      contentId =
        "87173654316145541646904042090629917349369185510102051783618763191692466404071"
      # or
      contentIdHexBE =
        "c0ba8a33ac67f44abff5984dfbb6f56c46b880ac2b86e1f23e7fa9c402c53ae7"

    let contentKey = ContentKey(
      contentType: masterAccumulator,
      masterAccumulatorKey: MasterAccumulatorKey(accumulaterKeyType: latest))

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex == contentKeyHex
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.masterAccumulatorKey.accumulaterKeyType ==
        contentKey.masterAccumulatorKey.accumulaterKeyType

      toContentId(contentKey) == parse(contentId, Stuint[256], 10)
      # In stint this does BE hex string
      toContentId(contentKey).toHex() == contentIdHexBE

  test "Master Accumulator - Hash":
    var accumulatorHash: Digest
    accumulatorHash.data = hexToByteArray[sizeof(Digest)](
      "0x88cce8439ebc0c1d007177ffb6831c15c07b4361984cc52235b6fd728434f0c7")

    const
      contentKeyHex =
        "040188cce8439ebc0c1d007177ffb6831c15c07b4361984cc52235b6fd728434f0c7"
      contentId =
        "79362820890138237094338894474079140563693945795365426184460738681339857347750"
      # or
      contentIdHexBE =
        "af75c3c9d0e89a5083361a3334a9c5583955f0dbe9a413eb79ba26400d1824a6"

    let contentKey = ContentKey(
      contentType: masterAccumulator,
      masterAccumulatorKey: MasterAccumulatorKey(
        accumulaterKeyType: masterHash, masterHashKey: accumulatorHash))

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex == contentKeyHex
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.masterAccumulatorKey.accumulaterKeyType ==
        contentKey.masterAccumulatorKey.accumulaterKeyType
      contentKeyDecoded.masterAccumulatorKey.masterHashKey ==
        contentKey.masterAccumulatorKey.masterHashKey

      toContentId(contentKey) == parse(contentId, Stuint[256], 10)
      # In stint this does BE hex string
      toContentId(contentKey).toHex() == contentIdHexBE
