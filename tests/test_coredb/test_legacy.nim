# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  std/strformat,
  eth/common,
  results,
  unittest2,
  ../../nimbus/[core/chain],
  ../replay/[undump_blocks, xcheck],
  ./test_helpers

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc test_chainSyncLegacyApi*(
    noisy: bool;
    filePath: string;
    com: CommonRef;
    numBlocks: int;
      ): bool =
  ## Store persistent blocks from dump into chain DB
  let
    sayBlocks = 900.u256
    chain = com.newChain

  for w in filePath.undumpBlocks:
    let (fromBlock, toBlock) = (w[0][0].blockNumber, w[0][^1].blockNumber)
    if fromBlock == 0.u256:
      xCheck w[0][0] == com.db.getBlockHeader(0.u256)
      continue

    # Message if [fromBlock,toBlock] contains a multiple of `sayBlocks`
    if fromBlock + (toBlock mod sayBlocks) <= toBlock:
      noisy.say "***", &"processing ...[#{fromBlock},#{toBlock}]..."

    xCheck chain.persistBlocks(w[0], w[1]) == ValidationResult.OK
    if numBlocks.toBlockNumber <= w[0][^1].blockNumber:
      break

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
