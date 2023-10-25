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
  chronicles,
  eth/common,
  results,
  unittest2,
  ../../nimbus/[core/chain],
  ../replay/[undump_blocks, xcheck],
  ./test_helpers

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc setTraceLevel {.used.} =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.TRACE)

proc setErrorLevel {.used.} =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.ERROR)

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc test_chainSync*(
    noisy: bool;
    filePath: string;
    com: CommonRef;
    numBlocks = high(int);
    lastOneExtra = true
      ): bool =
  ## Store persistent blocks from dump into chain DB
  let
    sayBlocks = 900.u256
    chain = com.newChain
    lastBlock = max(1, numBlocks - 1).toBlockNumber

  for w in filePath.undumpBlocks:
    let (fromBlock, toBlock) = (w[0][0].blockNumber, w[0][^1].blockNumber)
    if fromBlock == 0.u256:
      xCheck w[0][0] == com.db.getBlockHeader(0.u256)
      continue

    if toBlock < lastBlock:
      # Message if `[fromBlock,toBlock]` contains a multiple of `sayBlocks`
      if fromBlock + (toBlock mod sayBlocks) <= toBlock:
        noisy.say "***", &"processing ...[#{fromBlock},#{toBlock}]..."
      let runPersistBlocksRc = chain.persistBlocks(w[0], w[1])
      xCheck runPersistBlocksRc == ValidationResult.OK:
        if noisy:
          # Re-run with logging enabled
          setTraceLevel()
          discard chain.persistBlocks(w[0], w[1])
      continue

    # Make sure that the `lastBlock` is the first item of the argument batch.
    # So It might be necessary to Split off all blocks smaller than `lastBlock`
    # and execute them first. Then the next batch starts with the `lastBlock`.
    let
      pivot = (lastBlock - fromBlock).truncate(uint)
      headers9 = w[0][pivot .. ^1]
      bodies9 = w[1][pivot .. ^1]
    doAssert lastBlock == headers9[0].blockNumber

    # Process leading betch before `lastBlock` (if any)
    var dotsOrSpace = "..."
    if fromBlock < lastBlock:
      let
        headers1 = w[0][0 ..< pivot]
        bodies1 = w[1][0 ..< pivot]
      noisy.say "***", &"processing {dotsOrSpace}[#{fromBlock},#{lastBlock-1}]"
      let runPersistBlocks1Rc = chain.persistBlocks(headers1, bodies1)
      xCheck runPersistBlocks1Rc == ValidationResult.OK
      dotsOrSpace = "   "

    if noisy:
      setTraceLevel()
      com.db.trackLegaApi = true
      com.db.trackNewApi = true
      com.db.trackLedgerApi = true
      com.db.localDbOnly = true
    if lastOneExtra:
      let
        headers0 = headers9[0..0]
        bodies0 = bodies9[0..0]
      noisy.say "***", &"processing {dotsOrSpace}[#{lastBlock},#{lastBlock}]"
      let runPersistBlocks0Rc = chain.persistBlocks(headers0, bodies0)
      xCheck runPersistBlocks0Rc == ValidationResult.OK
    else:
      noisy.say "***", &"processing {dotsOrSpace}[#{lastBlock},#{toBlock}]"
      let runPersistBlocks9Rc = chain.persistBlocks(headers9, bodies9)
      xCheck runPersistBlocks9Rc == ValidationResult.OK

    break

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
