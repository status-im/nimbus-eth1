# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
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
  ../../../network/history/[history_content, accumulator]

# According to test vectors:
# https://github.com/ethereum/portal-network-specs/blob/master/content-keys-test-vectors.md#history-network-keys

suite "History ContentKey Encodings":
  test "BlockHeader":
    # Input
    const blockHash = BlockHash.fromHex(
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

    let contentKey = ContentKey(
      contentType: blockHeader, blockHeaderKey: BlockKey(blockHash: blockHash)
    )

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
    const blockHash = BlockHash.fromHex(
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

    let contentKey =
      ContentKey(contentType: blockBody, blockBodyKey: BlockKey(blockHash: blockHash))

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
    const blockHash = BlockHash.fromHex(
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

    let contentKey =
      ContentKey(contentType: receipts, receiptsKey: BlockKey(blockHash: blockHash))

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

  test "Epoch Accumulator":
    # Input
    const epochHash = Digest.fromHex(
      "0xe242814b90ed3950e13aac7e56ce116540c71b41d1516605aada26c6c07cc491"
    )

    # Output
    const
      contentKeyHex =
        "03e242814b90ed3950e13aac7e56ce116540c71b41d1516605aada26c6c07cc491"
      contentId =
        "72232402989179419196382321898161638871438419016077939952896528930608027961710"
      # or
      contentIdHexBE =
        "9fb2175e76c6989e0fdac3ee10c40d2a81eb176af32e1c16193e3904fe56896e"

    let contentKey = ContentKey(
      contentType: epochRecord, epochRecordKey: EpochRecordKey(epochHash: epochHash)
    )

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex == contentKeyHex
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.epochRecordKey == contentKey.epochRecordKey

      toContentId(contentKey) == parse(contentId, StUint[256], 10)
      # In stint this does BE hex string
      toContentId(contentKey).toHex() == contentIdHexBE
