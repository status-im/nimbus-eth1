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

## Snap sync components tester

import
  std/[random, sequtils, strformat, strutils],
  chronicles,
  eth/common/eth_types,
  stint,
  stew/results,
  unittest2,
  ../nimbus/sync/[types, protocol/snap1],
  ../nimbus/sync/snap/path_desc,
  ../nimbus/sync/snap/worker/fetch/proof_db,
  ./replay/pp,
  ./test_sync_snap/accounts_and_proofs

type
  TestSample = tuple ## sample format from `accounts_and_proofs`
    base: Hash256
    accounts: seq[(Hash256,uint64,UInt256,Hash256,Hash256)]
    proofs: seq[Blob]

  TestItem = object ## palatable input format for tests
    base: NodeTag
    accounts: seq[SnapAccount]
    proofs: SnapAccountProof

let
  # Forces `check()` to print the error (as opposed when using `isOk()`)
  OkProof = Result[void,ProofError].ok()

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc pp(w: TrieHash): string =
  w.Hash256.pp

proc setTraceLevel =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.TRACE)

proc setErrorLevel =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.ERROR)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc to(data: seq[TestSample]; T: type seq[TestItem]): T =
  ## Convert test data into usable format
  for r in  data:
    result.add TestItem(
      base:     r.base.to(NodeTag),
      accounts: r.accounts.mapIt(
        SnapAccount(
          accHash:       it[0].to(NodeTag),
          accBody: Account(
            nonce:       it[1],
            balance:     it[2],
            storageRoot: it[3],
            codeHash:    it[4]))),
      proofs:   r.proofs)

proc permute(r: var Rand; qLen: int): seq[int]  =
  result = (0 ..< qLen).toSeq
  let
    halfLen = result.len shr 1
    randMax = result.len - halfLen - 1
  for left in 0 ..< halfLen:
    let right = halfLen + r.rand(randMax)
    result[left].swap(result[right])

# ------------------------------------------------------------------------------
# Test Runners
# ------------------------------------------------------------------------------

proc accountsRunner(noisy = true; root: TrieHash; data: seq[TestSample]) =
  let lst = data.to(seq[TestItem])

  suite "SyncSnap: ccounts and proofs db":
    let desc = ProofDBRef.init(root)
    var nRows: seq[int]

    test &"Merging {lst.len} proofs for state root ..{root.pp}":
      for proofs in lst.mapIt(it.proofs):
        check desc.merge(proofs) == OkProof
        check desc.validate == OkProof
        nRows.add desc.proofsLen
      check 1 < nRows.len # otherwise test makes no sense
      check 0 < nRows[^1]

    test "Rollback full database":
      desc.rollback()
      check desc.proofsLen == 0
      check desc.journalLen == (0,0,0)

    test "Merging and committing all except the last":
      for n,proofs in lst.mapIt(it.proofs):
        check desc.merge(proofs) == OkProof
        check nRows[n] == desc.proofsLen
        check desc.validate == OkProof
        if n < nRows.len - 1:
          desc.commit
        check nRows[n] == desc.proofsLen
      desc.rollback
      check 1 < nRows.len and nRows[^2] == desc.proofsLen

    test &"Merging/committing {lst.len} proofs, transposed rows":
      desc.clear
      check desc.proofsLen == 0
      check desc.journalLen == (0,0,0)
      var r = initRand(42)
      for n,proofs in lst.mapIt(it.proofs):
        let permProof = r.permute(proofs.len).mapIt(proofs[it])
        check desc.merge(permProof) == OkProof
        check desc.validate == OkProof
        desc.commit
        check nRows[n] == desc.proofsLen

    test &"Merging {lst.len} prooved account groups"&
        &" for state root ..{root.pp}":
      desc.clear
      for n,w in lst:
        check desc.mergeProved(w.base, w.accounts, w.proofs) == OkProof
        check desc.journalLen == (0,0,0)
        check desc.validate == OkProof
        check nRows[n] == desc.proofsLen
        check desc.journalLen == (0,0,0)
      check 1 < nRows.len # otherwise test makes no sense
      check 0 < nRows[^1]

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc syncSnapMain*(noisy = defined(debug)) =
  noisy.accountsRunner(testRoot.TrieHash, testSamples)

when isMainModule:
  const noisy = defined(debug) or true

  when true: # false:
    # Import additional data from test data repo
    import ../../nimbus-eth1-blobs/replay/accounts_and_proofs_ex
  else:
    const
      testRootEx = testRoot
      testSamplesEx = newSeq[TestSample]()

  setTraceLevel()

  # Verify sample state roots
  doAssert testRoot == testRootEx

  let samplesList = (testSamples & testSamplesEx)
  noisy.accountsRunner(testRoot.TrieHash, samplesList)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
