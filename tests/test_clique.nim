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
  # ../nimbus/p2p/clique,
  ../nimbus/utils,
  ./test_clique/pool,
  eth/[keys],
  # sequtils,
  stint,
  strformat,
  # times,
  unittest2

proc initSnapshot(p: TesterPool; t: TestSpecs; noisy: bool): auto =

  # Assemble a chain of headers from the cast votes
  p.resetVoterChain(t.signers)
  for voter in t.votes:
    p.appendVoter(voter)
  p.commitVoterChain

  let topHeader = p.topVoterHeader
  p.snapshot(topHeader.blockNumber, topHeader.hash, @[])


proc notUsedYet(p: TesterPool; tt: TestSpecs; noisy: bool) =
  discard
  #[
    # Verify the final list of signers against the expected ones
    signers = make([]common.Address, len(tt.results))
    for j, signer := range tt.results {
      signers[j] = accounts.address(signer)
    }
    for j := 0; j < len(signers); j++ {
      for k := j + 1; k < len(signers); k++ {
	if bytes.Compare(signers[j][:], signers[k][:]) > 0 {
	  signers[j], signers[k] = signers[k], signers[j]
	}
      }
    }
    result := snap.signers()
    if len(result) != len(signers) {
      t.Errorf("test %d: signers mismatch: have %x, want %x",i,result,signers)
      continue
    }
    for j := 0; j < len(result); j++ {
      if !bytes.Equal(result[j][:], signers[j][:]) {
	t.Errorf(
          "test %d, signer %d: signer mismatch: have %x, want %x",
          i, j, result[j], signers[j])
      }
    }
  ]#

# clique/snapshot_test.go(99): func TestClique(t *testing.T) {
proc cliqueMain*(noisy = defined(debug)) =
  ## Tests that Clique signer voting is evaluated correctly for various simple
  ## and complex scenarios, as well as that a few special corner cases fail
  ## correctly.
  suite "Clique PoA Snapshot":
    var
      pool = newTesterPool()
      testSet = {0 .. 99}

    # clique/snapshot_test.go(379): for i, tt := range tests {
    for tt in voterSamples:
      if tt.id in testSet:
        test &"Snapshots {tt.id}: {tt.info.substr(0,50)}...":
          var snap = pool.initSnapshot(tt, noisy)
          if snap.isErr:
            # FIXME: double check error behavior
            check snap.error[0] == tt.failure


when isMainModule:
  cliqueMain()

# End
