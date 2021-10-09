# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  unittest2, stint, stew/[byteutils, results],
  ../network/history/history_content

suite "History ContentKey Encodings":
  test "ContentKey":
    var blockHash: BlockHash # All zeroes
    let contentKey = ContentKey(chainId: 1'u16, contentType: BlockBody, blockHash: blockHash)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex ==
      "0100020000000000000000000000000000000000000000000000000000000000000000"
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKey2 = decoded.get()
    check:
      contentKey2.chainId == 1'u16
      contentKey2.contentType == BlockBody
      contentKey2.blockHash == blockHash
