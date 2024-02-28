# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  stew/results,
  eth/common/eth_types_rlp,
  ../network/history/[history_content, accumulator]

export results, accumulator, history_content

proc buildHeadersWithProof*(
    blockHeaders: seq[BlockHeader], epochAccumulator: EpochAccumulatorCached
): Result[seq[(seq[byte], seq[byte])], string] =
  var blockHeadersWithProof: seq[(seq[byte], seq[byte])]
  for header in blockHeaders:
    if header.isPreMerge():
      let
        content = ?buildHeaderWithProof(header, epochAccumulator)
        contentKey = ContentKey(
          contentType: blockHeader,
          blockHeaderKey: BlockKey(blockHash: header.blockHash()),
        )

      blockHeadersWithProof.add((encode(contentKey).asSeq(), SSZ.encode(content)))

  ok(blockHeadersWithProof)
