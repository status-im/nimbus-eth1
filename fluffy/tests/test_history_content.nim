# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  unittest2, stew/byteutils,
  ../network/history/history_content

# According to test vectors:
# TODO: Add link once test vectors are merged
suite "History ContentKey Encodings":
  test "BlockHeader":
    var blockHash: BlockHash
    blockHash.data = hexToByteArray[sizeof(BlockHash)](
      "0xd1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d")
    let contentKey =
      ContentKey(chainId: 15'u16, contentType: BlockHeader, blockHash: blockHash)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex ==
      "0f0001d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
      # "010f00d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.chainId == contentKey.chainId
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.blockHash == contentKey.blockHash

      toContentId(contentKey).toHex() ==
        "9a310df5e6135cbd834041011be1b350e589ba013f11584ed527583bc39d3c27"

  test "BlockBody":
    var blockHash: BlockHash
    blockHash.data = hexToByteArray[sizeof(BlockHash)](
      "0xd1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d")
    let contentKey =
      ContentKey(chainId: 20'u16, contentType: BlockBody, blockHash: blockHash)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex ==
      "140002d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
      # "021400d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.chainId == contentKey.chainId
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.blockHash == contentKey.blockHash

      toContentId(contentKey).toHex() ==
        "42a9bb9fd974f4d3020fe81aa584277010a9e344bed52bf1610e9d360203380a"

  test "Receipts":
    var blockHash: BlockHash
    blockHash.data = hexToByteArray[sizeof(BlockHash)](
      "0xd1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d")
    let contentKey =
      ContentKey(chainId: 4'u16, contentType: Receipts, blockHash: blockHash)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex ==
      "040003d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
      # "030400d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.chainId == contentKey.chainId
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.blockHash == contentKey.blockHash

      toContentId(contentKey).toHex() ==
        "4b92510bafa02f62811ce6d0e27d2424ba34d41fbe38abc3ea4e274d6c76fa3e"
