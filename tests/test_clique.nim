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
  ../nimbus/config,
  ../nimbus/db/db_chain,
  ../nimbus/p2p/[chain, clique, clique/snapshot],
  ../nimbus/utils,
  ./test_clique/[pool, undump],
  eth/[common, keys],
  stint,
  unittest2

let
  goerliCapture = "test_clique" / "goerli51840.txt.gz"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc db(ap: TesterPool): auto =
  ## Getter
  ap.clique.db

proc getBlockHeader(ap: TesterPool; number: BlockNumber): BlockHeader =
  ## Shortcut => db/db_chain.getBlockHeader()
  doAssert ap.db.getBlockHeader(number, result)

# ------------------------------------------------------------------------------
# Test Runners
# ------------------------------------------------------------------------------

# clique/snapshot_test.go(99): func TestClique(t *testing.T) {
proc runCliqueSnapshot(noisy = true) =
  ## Clique PoA Snapshot
  ## ::
  ##    Tests that Clique signer voting is evaluated correctly for various
  ##    simple and complex scenarios, as well as that a few special corner
  ##    cases fail correctly.
  ##
  suite "Clique PoA Snapshot":
    var
      pool = newVoterPool().setDebug(noisy)
    const
      skipSet = {999}
      testSet = {0 .. 999}

    # clique/snapshot_test.go(379): for i, tt := range tests {
    for tt in voterSamples.filterIt(it.id in testSet):

      test &"Snapshots {tt.id:2}: {tt.info.substr(0,50)}...":
        pool.say "\n"

        if tt.id in skipSet:
          skip()

        else:
          # Assemble a chain of headers from the cast votes
          # see clique/snapshot_test.go(407): config := *params.TestChainConfig
          pool
            .resetVoterChain(tt.signers, tt.epoch)
            # see clique/snapshot_test.go(425): for j, block := range blocks {
            .appendVoter(tt.votes)
            .commitVoterChain

          # see clique/snapshot_test.go(476): snap, err := engine.snapshot( [..]
          let topHeader = pool.topVoterHeader
          var snap = pool.snapshot(topHeader.blockNumber, topHeader.hash, @[])

          # see clique/snapshot_test.go(477): if err != nil {
          if snap.isErr:
            # Note that clique/snapshot_test.go does not verify _here_ against
            # the scheduled test error -- rather this voting error is supposed
            # to happen earlier (processed at clique/snapshot_test.go(467)) when
            # assembling the block chain (sounds counter intuitive to the author
            # of this source file as the scheduled errors are _clique_ related).
            check snap.error[0] == tt.failure
          else:
            let
              expected = tt.results.mapIt("@" & it).sorted
              snapResult = pool.pp(snap.value.signers).sorted
            pool.say "*** snap state=", snap.pp(16)
            pool.say "        result=[", snapResult.join(",") & "]"
            pool.say "      expected=[", expected.join(",") & "]"

            # Verify the final list of signers against the expected ones
            check snapResult == expected


proc runGoerliReplay(noisy = true;
                     dir = "tests"; stopAfterBlock = uint64.high) =
  var
    pool = GoerliNet.newVoterPool
    xChain = pool.db.newChain
    cache: array[7,(seq[BlockHeader],seq[BlockBody])]
    cInx = 0
    stoppedOk = false

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
        if stopAfterBlock <= cache[cInx-1][0][0].blockNumber.truncate(uint64):
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
              let addedPersistBlocks = xChain.persistBlocks(headers, bodies)
              check addedPersistBlocks == ValidationResult.Ok
              if addedPersistBlocks != ValidationResult.Ok: return

    # Rest from cache
    if 0 < cInx:
      let
        first = cache[0][0][0].blockNumber
        last = cache[cInx-1][0][^1].blockNumber
      test &"Goerli Blocks #{first}..#{last} ({cInx} transactions)":
        for (headers,bodies) in cache:
          let addedPersistBlocks = xChain.persistBlocks(headers, bodies)
          check addedPersistBlocks == ValidationResult.Ok
          if addedPersistBlocks != ValidationResult.Ok: return

    if stoppedOk:
      test &"Runner stooped after reaching #{stopAfterBlock}":
        discard

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc cliqueMain*(noisy = defined(debug)) =
  noisy.runCliqueSnapshot
  noisy.runGoerliReplay

when isMainModule:
  let noisy = defined(debug)
  noisy.runCliqueSnapshot
  noisy.runGoerliReplay(dir = ".", stopAfterBlock = 1000)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
