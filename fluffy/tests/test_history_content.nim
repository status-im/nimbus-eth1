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

suite "History ContentKey Encodings":
  test "ContentKey":
    var blockHash: BlockHash
    blockHash.data = hexToByteArray[sizeof(BlockHash)](
      "0x0100000000000000000000000000000000000000000000000000000000000000")
    let contentKey =
      ContentKey(chainId: 1'u16, contentType: BlockBody, blockHash: blockHash)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex ==
      "0100020100000000000000000000000000000000000000000000000000000000000000"
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.chainId == contentKey.chainId
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.blockHash == contentKey.blockHash

      toContentId(contentKey).toHex() ==
        "36a55e9aa5125c5fecc16bcb0234d9d3d6065eabc890c0d3b24d413d6ae9f9da"
