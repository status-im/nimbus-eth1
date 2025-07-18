# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  unittest2,
  stew/byteutils,
  stint,
  ssz_serialization,
  ssz_serialization/[proofs, merkleization],
  ../../network/legacy_history/history_content

# According to test vectors:
# https://github.com/ethereum/portal-network-specs/blob/master/content-keys-test-vectors.md#history-network-keys

suite "History Content Keys":
  test "BlockHeader":
    # Input
    const blockHash = Hash32.fromHex(
      "0xd1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
    )

    # Output
    const
      contentKeyHex =
        "00d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
      contentId =
        "28281392725701906550238743427348001871342819822834514257505083923073246729726"
      # or
      contentIdHexBE =
        "3e86b3767b57402ea72e369ae0496ce47cc15be685bec3b4726b9f316e3895fe"

    let contentKey = blockHeaderContentKey(blockHash)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex == contentKeyHex
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.blockHeaderKey == contentKey.blockHeaderKey

      toContentId(contentKey) == parse(contentId, StUint[256], 10)
      # In stint this does BE hex string
      toContentId(contentKey).toHex() == contentIdHexBE

  test "BlockBody":
    # Input
    const blockHash = Hash32.fromHex(
      "0xd1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
    )

    # Output
    const
      contentKeyHex =
        "01d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
      contentId =
        "106696502175825986237944249828698290888857178633945273402044845898673345165419"
      # or
      contentIdHexBE =
        "ebe414854629d60c58ddd5bf60fd72e41760a5f7a463fdcb169f13ee4a26786b"

    let contentKey = blockBodyContentKey(blockHash)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex == contentKeyHex
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
    const blockHash = Hash32.fromHex(
      "0xd1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
    )

    # Output
    const
      contentKeyHex =
        "02d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"
      contentId =
        "76230538398907151249589044529104962263309222250374376758768131420767496438948"
      # or
      contentIdHexBE =
        "a888f4aafe9109d495ac4d4774a6277c1ada42035e3da5e10a04cc93247c04a4"

    let contentKey = receiptsContentKey(blockHash)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex == contentKeyHex
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.receiptsKey == contentKey.receiptsKey

      toContentId(contentKey) == parse(contentId, StUint[256], 10)
      # In stint this does BE hex string
      toContentId(contentKey).toHex() == contentIdHexBE

  test "BlockHeader by Number":
    # Input
    const blockNumber = 12345678'u64

    # Output
    const
      contentKeyHex = "034e61bc0000000000"
      contentId =
        "14960950260935695396511307566164035182676768442501235074589175304147024756175"
      # or
      contentIdHexBE =
        "2113990747a85ab39785d21342fa5db1f68acc0011605c0c73f68fc331643dcf"

    let contentKey = blockHeaderContentKey(blockNumber)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex == contentKeyHex
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.blockNumberKey == contentKey.blockNumberKey

      toContentId(contentKey) == parse(contentId, StUint[256], 10)
      # In stint this does BE hex string
      toContentId(contentKey).toHex() == contentIdHexBE

  test "Ephemeral BlockHeaders - by FindContent":
    # Input
    const
      blockHash = Hash32.fromHex(
        "0xd24fd73f794058a3807db926d8898c6481e902b7edb91ce0d479d6760f276183"
      )
      ancestorCount = 1'u8

    # Output
    const
      contentKeyHex =
        "04d24fd73f794058a3807db926d8898c6481e902b7edb91ce0d479d6760f27618301"
      contentId =
        "86673067728773827953572202865791108477333088977683100454782145089217210483928"
      # or
      contentIdHexBE =
        "bf9f37c72f6635bbe8dbb4d9377a56d8d579a434399f4c5ba4aad5a213ca04d8"

    let contentKey = ephemeralBlockHeaderFindContentContentKey(blockHash, ancestorCount)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex == contentKeyHex
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.ephemeralBlockHeaderFindContentKey ==
        contentKey.ephemeralBlockHeaderFindContentKey

      toContentId(contentKey) == parse(contentId, StUint[256], 10)
      # In stint this does BE hex string
      toContentId(contentKey).toHex() == contentIdHexBE

  test "Ephemeral BlockHeaders - by Offer":
    # Input
    const blockHash = Hash32.fromHex(
      "0xd24fd73f794058a3807db926d8898c6481e902b7edb91ce0d479d6760f276183"
    )

    # Output
    const
      contentKeyHex =
        "05d24fd73f794058a3807db926d8898c6481e902b7edb91ce0d479d6760f276183"
      contentId =
        "53578383365152416879548583252310683576041629183471230085103111329525692700007"
      # or
      contentIdHexBE =
        "76744a5338183a04ea39bbb94906e539b9a839b4aa508f8493b2afbba2491567"

    let contentKey = ephemeralBlockHeaderOfferContentKey(blockHash)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex == contentKeyHex
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.ephemeralBlockHeaderOfferKey ==
        contentKey.ephemeralBlockHeaderOfferKey

      toContentId(contentKey) == parse(contentId, StUint[256], 10)
      # In stint this does BE hex string
      toContentId(contentKey).toHex() == contentIdHexBE
