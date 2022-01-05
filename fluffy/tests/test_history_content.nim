# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  unittest2, stew/byteutils, stint,
  ../network/history/history_content

# According to test vectors:
# TODO: Add link once test vectors are merged
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
      blockHeaderKey: ContentKeyType(chainId: 15'u16, blockHash: blockHash))

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
      blockBodyKey: ContentKeyType(chainId: 20'u16, blockHash: blockHash))

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
      receiptsKey: ContentKeyType(chainId: 4'u16, blockHash: blockHash))


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
