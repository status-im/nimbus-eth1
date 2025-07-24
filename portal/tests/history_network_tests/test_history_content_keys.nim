# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import unittest2, stew/byteutils, ../../network/history/history_content

suite "History Network Content Keys":
  test "toContentId":
    # Input
    const blockNumbers = [
      1.uint64,
      1000.uint64,
      12_345_678.uint64,
      uint64.high(),
      uint64.high() - 1,
      uint64.high() div 2,
      uint64.high() div 16 + 1,
      6148914691236517205'u64,
      12297829382473034410'u64,
      11574427654092267680'u64,
    ]

    # Output
    const contentIds = [
      "0001000000000000000000000000000000000000000000000000000000000001",
      "03e8000000000000000000000000000000000000000000000000000000000001",
      "614e3d0000000000000000000000000000000000000000000000000000000001",
      "ffffffffffffffff000000000000000000000000000000000000000000000001",
      "fffeffffffffffff000000000000000000000000000000000000000000000001",
      "fffffffffffffffe000000000000000000000000000000000000000000000001",
      "0000000000000008000000000000000000000000000000000000000000000001",
      "5555aaaaaaaaaaaa000000000000000000000000000000000000000000000001",
      "aaaa555555555555000000000000000000000000000000000000000000000001",
      "a0a0050505050505000000000000000000000000000000000000000000000001",
    ]

    for i in 0 ..< blockNumbers.len():
      let contentId = toContentId(blockNumbers[i], ContentType.receipts)

      check contentIds[i] == contentId.dumpHex()

  test "BlockBody":
    # Input
    const blockNumber = 12_345_678.uint64

    # Output
    const
      contentKeyHex = "0x004e61bc0000000000"
      contentId =
        "44012581390156707874310974263613699127815223388818970640389075388176810377216"
      # or
      contentIdHexBE =
        "614e3d0000000000000000000000000000000000000000000000000000000000"

    let contentKey = blockBodyContentKey(blockNumber)

    let encoded = encode(contentKey)
    check encoded.asSeq.to0xHex == contentKeyHex
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.blockBodyKey == contentKey.blockBodyKey

      toContentId(contentKey) == parse(contentId, StUint[256], 10)
      # In stint this does BE hex string
      toContentId(contentKey).toHex() == contentIdHexBE

  test "Receipts":
    # Input
    const blockNumber = 12_345_678.uint64

    # Output
    const
      contentKeyHex = "0x014e61bc0000000000"
      contentId =
        "44012581390156707874310974263613699127815223388818970640389075388176810377217"
      # or
      contentIdHexBE =
        "614e3d0000000000000000000000000000000000000000000000000000000001"

    let contentKey = receiptsContentKey(blockNumber)

    let encoded = encode(contentKey)
    check encoded.asSeq.to0xHex == contentKeyHex
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.receiptsKey == contentKey.receiptsKey

      toContentId(contentKey) == parse(contentId, StUint[256], 10)
      # In stint this does BE hex string
      toContentId(contentKey).toHex() == contentIdHexBE

  test "Invalid prefix - after valid range":
    let encoded = ContentKeyByteList.init(@[byte 0x02])
    let decoded = decode(encoded)

    check decoded.isErr()

  test "Invalid key - empty input":
    let encoded = ContentKeyByteList.init(@[])
    let decoded = decode(encoded)

    check decoded.isErr()
