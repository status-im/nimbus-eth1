# fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## File do be deleted when pruneDeprecatedAccumulatorRecords has been active
## for long enough that most users have upgraded and as a result cleaned up
## their database.

{.push raises: [].}

import
  nimcrypto/[sha2, hash],
  stint,
  chronicles,
  ssz_serialization,
  ../../../common/common_types,
  ../../../database/content_db,
  ../accumulator

type
  ContentType = enum
    blockHeader = 0x00
    blockBody = 0x01
    receipts = 0x02
    epochRecordDeprecated = 0x03

  BlockKey = object
    blockHash: BlockHash

  EpochRecordKeyDeprecated = object
    epochHash: Digest

  ContentKey = object
    case contentType: ContentType
    of blockHeader:
      blockHeaderKey: BlockKey
    of blockBody:
      blockBodyKey: BlockKey
    of receipts:
      receiptsKey: BlockKey
    of epochRecordDeprecated:
      epochRecordKeyDeprecated: EpochRecordKeyDeprecated

func encode(contentKey: ContentKey): ContentKeyByteList =
  ContentKeyByteList.init(SSZ.encode(contentKey))

func toContentId(contentKey: ContentKeyByteList): ContentId =
  let idHash = sha2.sha256.digest(contentKey.asSeq())
  readUintBE[256](idHash.data)

proc pruneDeprecatedAccumulatorRecords*(
    accumulator: FinishedAccumulator, contentDB: ContentDB
) =
  info "Pruning deprecated accumulator records"

  for i, hash in accumulator.historicalEpochs:
    let
      root = Digest(data: hash)
      epochRecordKey = ContentKey(
        contentType: epochRecordDeprecated,
        epochRecordKeyDeprecated: EpochRecordKeyDeprecated(epochHash: root),
      )
      encodedKey = encode(epochRecordKey)
      contentId = toContentId(encodedKey)

    contentDB.del(contentId)

  info "Pruning deprecated accumulator records finished"
