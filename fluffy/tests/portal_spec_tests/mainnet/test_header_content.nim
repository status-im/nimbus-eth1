# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

{.push raises: [].}

import unittest2, stew/byteutils, ../../../network/header/header_content

suite "Header Gossip ContentKey Encodings":
  test "BlockHeader":
    # Input
    const
      blockHash = BlockHash.fromHex(
        "0xd1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
      )
      blockNumber = 2.stuint(256)

    # Output
    const
      contentKeyHex =
        "00d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d0200000000000000000000000000000000000000000000000000000000000000"
      contentId =
        "93053813395975896824800219097617621670658136800980011170166846009189305194644"
      # or
      contentIdHexBE =
        "cdba9789eec7a1994ec7c033c46c2c94242da2c016051bf09240fd9a81589894"

    let contentKey = ContentKey(
      contentType: newBlockHeader,
      newBlockHeaderKey:
        NewBlockHeaderKey(blockHash: blockHash, blockNumber: blockNumber),
    )

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex == contentKeyHex
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.newBlockHeaderKey == contentKey.newBlockHeaderKey

      toContentId(contentKey) == parse(contentId, StUint[256], 10)
      # In stint this does BE hex string
      toContentId(contentKey).toHex() == contentIdHexBE
