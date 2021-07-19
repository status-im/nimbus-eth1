# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[algorithm, os, sequtils, strformat, strutils],
  ../nimbus/db/db_chain,
  ../nimbus/p2p/[chain, clique, clique/clique_snapshot],
  ./test_clique/[pool, undump],
  eth/[common, keys],
  stint,
  unittest2

let
  goerliCapture = "test_clique" / "goerli51840.txt.gz"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc getBlockHeader(ap: TesterPool; number: BlockNumber): BlockHeader =
  ## Shortcut => db/db_chain.getBlockHeader()
  doAssert ap.db.getBlockHeader(number, result)

# ------------------------------------------------------------------------------
# Test Runners
# ------------------------------------------------------------------------------

# clique/snapshot_test.go(99): func TestClique(t *testing.T) {
proc runCliqueSnapshot(noisy = true; postProcessOk = false;
                       testIds = {0 .. 999}; skipIds = {0}-{0}) =
  ## Clique PoA Snapshot
  ## ::
  ##    Tests that Clique signer voting is evaluated correctly for various
  ##    simple and complex scenarios, as well as that a few special corner
  ##    cases fail correctly.
  ##
  let postProcessInfo = if postProcessOk: ", Transaction Finaliser Applied"
                        else: ", Without Finaliser"
  suite &"Clique PoA Snapshot{postProcessInfo}":
    var
      pool = newVoterPool()

    pool.debug = noisy

    # clique/snapshot_test.go(379): for i, tt := range tests {
    for tt in voterSamples.filterIt(it.id in testIds):

      test &"Snapshots {tt.id:2}: {tt.info.substr(0,50)}...":
        pool.say "\n"

        # Noisily skip this test
        if tt.id in skipIds:
          skip()

        else:
          # Assemble a chain of headers from the cast votes
          # see clique/snapshot_test.go(407): config := *params.TestChainConfig
          pool
            .resetVoterChain(tt.signers, tt.epoch)
            # see clique/snapshot_test.go(425): for j, block := range blocks {
            .appendVoter(tt.votes)
            .commitVoterChain(postProcessOk)

          # see clique/snapshot_test.go(477): if err != nil {
          if tt.failure != cliqueNoError[0]:
            # Note that clique/snapshot_test.go does not verify _here_ against
            # the scheduled test error -- rather this voting error is supposed
            # to happen earlier (processed at clique/snapshot_test.go(467)) when
            # assembling the block chain (sounds counter intuitive to the author
            # of this source file as the scheduled errors are _clique_ related).
            check pool.failed[1][0] == tt.failure
          else:
            let
              expected = tt.results.mapIt("@" & it).sorted
              snapResult = pool.pp(pool.cliqueSigners).sorted
            pool.say "*** snap state=", pool.snapshot.pp(16)
            pool.say "        result=[", snapResult.join(",") & "]"
            pool.say "      expected=[", expected.join(",") & "]"

            # Verify the final list of signers against the expected ones
            check snapResult == expected

proc runCliqueSnapshot(noisy = true; postProcessOk = false; testId: int) =
  noisy.runCliqueSnapshot(postProcessOk, testIds = {testId})


proc runGoerliReplay(noisy = true; dir = "tests"; stopAfterBlock = 0u64) =
  var
    pool = newVoterPool()
    cache: array[7,(seq[BlockHeader],seq[BlockBody])]
    cInx = 0
    stoppedOk = false

  pool.debug = noisy

  let stopThreshold = if stopAfterBlock == 0u64: uint64.high.u256
                      else: stopAfterBlock.u256

  suite "Replay Goerli Chain":

    for w in (dir / goerliCapture).undumpNextGroup:

      if w[0][0].blockNumber == 0.u256:
        # Verify Genesis
        doAssert w[0][0] == pool.getBlockHeader(0.u256)

      else:
        # Condense in cache
        cache[cInx] = w
        cInx.inc

        # Handy for partial tests
        if stopThreshold < cache[cInx-1][0][0].blockNumber:
          stoppedOk = true
          break

        # Run from cache if complete set
        if cache.len <= cInx:
          cInx = 0
          let
            first = cache[0][0][0].blockNumber
            last = cache[^1][0][^1].blockNumber
          test &"Goerli Blocks #{first}..#{last} ({cache.len} transactions)":
            for (headers,bodies) in cache:
              let addedPersistBlocks = pool.chain.persistBlocks(headers,bodies)
              check addedPersistBlocks == ValidationResult.Ok
              if addedPersistBlocks != ValidationResult.Ok: return

    # Rest from cache
    if 0 < cInx:
      let
        first = cache[0][0][0].blockNumber
        last = cache[cInx-1][0][^1].blockNumber
      test &"Goerli Blocks #{first}..#{last} ({cInx} transactions)":
        for (headers,bodies) in cache:
          let addedPersistBlocks = pool.chain.persistBlocks(headers,bodies)
          check addedPersistBlocks == ValidationResult.Ok
          if addedPersistBlocks != ValidationResult.Ok: return

    if stoppedOk:
      test &"Runner stopped after reaching #{stopThreshold}":
        discard


proc runGoerliBaybySteps(noisy = true; dir = "tests"; stopAfterBlock = 0u64) =
  var
    pool = newVoterPool()
    stoppedOk = false

  pool.debug = noisy

  let stopThreshold = if stopAfterBlock == 0u64: 20.u256
                      else: stopAfterBlock.u256

  suite "Replay Goerli Chain Transactions Single Blockwise":

    for w in (dir / goerliCapture).undumpNextGroup:
      if stoppedOk:
        break
      if w[0][0].blockNumber == 0.u256:
        # Verify Genesis
        doAssert w[0][0] == pool.getBlockHeader(0.u256)
      else:
        for n in 0 ..< w[0].len:
          let
            header = w[0][n]
            body = w[1][n]
          var
            parents = w[0][0 ..< n]
          test &"Goerli Block #{header.blockNumber} + {parents.len} parents":
            check pool.chain.clique.cliqueSnapshot(header,parents).isOk
            let addedPersistBlocks = pool.chain.persistBlocks(@[header],@[body])
            check addedPersistBlocks == ValidationResult.Ok
            if addedPersistBlocks != ValidationResult.Ok: return
          # Handy for partial tests
          if stopThreshold <= header.blockNumber:
            stoppedOk = true
            break

    if stoppedOk:
      test &"Runner stopped after reaching #{stopThreshold}":
        discard

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

let
  skipIDs = {999}

proc cliqueMain*(noisy = defined(debug)) =
  noisy.runCliqueSnapshot(true)
  noisy.runCliqueSnapshot(false, skipIDs = skipIDs)
  noisy.runGoerliBaybySteps
  noisy.runGoerliReplay

when isMainModule:
  let noisy = defined(debug)
  noisy.runCliqueSnapshot(true)
  noisy.runCliqueSnapshot(false)
  noisy.runGoerliBaybySteps(dir = ".")
  noisy.runGoerliReplay(dir = ".")

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
