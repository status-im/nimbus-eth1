# Nimbus
# Copyright (c) 2018-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[os, sequtils, strformat, strutils, tables],
  chronicles,
  ../nimbus/db/accounts_cache,
  ../nimbus/common/common,
  ../nimbus/core/chain,
  ../nimbus/transaction,
  ../nimbus/constants,
  ../nimbus/vm_state,
  ../nimbus/vm_types,
  ./replay/undump_blocks,
  unittest2

type
  CaptureSpecs = tuple
    network: NetworkId
    file: string
    numBlocks: int
    numTxs: int

const
  baseDir = [".", "tests", ".." / "tests", $DirSep] # path containg repo
  repoDir = ["replay", "status", "test_clique"]     # alternative repo paths

  goerliCapture: CaptureSpecs = (
    network: GoerliNet,
    file: "goerli68161.txt.gz",
    numBlocks: 5500,  # unconditionally load blocks
    numTxs:      10)  # txs following (not in block chain)

  goerliCapture1: CaptureSpecs = (
    GoerliNet, goerliCapture.file, 5500, 10000)

  mainCapture: CaptureSpecs = (
    MainNet, "mainnet843841.txt.gz", 50000, 3000)

var
  xdb: CoreDbRef
  txs: seq[Transaction]
  txi: seq[int] # selected index into txs[] (crashable sender addresses)

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc findFilePath(file: string): string =
  result = "?unknown?" / file
  for dir in baseDir:
    for repo in repoDir:
      let path = dir / repo / file
      if path.fileExists:
        return path

proc pp*(a: EthAddress): string =
  a.mapIt(it.toHex(2)).join[32 .. 39].toLowerAscii

proc pp*(tx: Transaction): string =
  # "(" & tx.ecRecover.value.pp & "," & $tx.nonce & ")"
  "(" & tx.getSender.pp & "," & $tx.nonce & ")"

proc pp*(h: KeccakHash): string =
  h.data.mapIt(it.toHex(2)).join[52 .. 63].toLowerAscii

proc pp*(tx: Transaction; vmState: BaseVMState): string =
  let address = tx.getSender
  "(" & address.pp &
    "," & $tx.nonce &
    ";" & $vmState.readOnlyStateDB.getNonce(address) &
    "," & $vmState.readOnlyStateDB.getBalance(address) &
    ")"

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

proc blockChainForTesting*(network: NetworkId): CommonRef =
  result = CommonRef.new(
    newCoreDbRef LegacyDbMemory,
    networkId = network,
    params = network.networkParams)
  initializeEmptyDb(result)

proc importBlocks(com: CommonRef; h: seq[BlockHeader]; b: seq[BlockBody]) =
  if com.newChain.persistBlocks(h,b) != ValidationResult.OK:
    raiseAssert "persistBlocks() failed at block #" & $h[0].blockNumber

proc getVmState(com: CommonRef; number: BlockNumber): BaseVMState =
  BaseVMState.new(com.db.getBlockHeader(number), com)

# ------------------------------------------------------------------------------
# Crash test function, finding out about how the transaction framework works ..
# ------------------------------------------------------------------------------

proc modBalance(ac: var AccountsCache, address: EthAddress) =
  ## This function is crucial for profucing the crash. If must
  ## modify the balance so that the database gets written.
  # ac.blindBalanceSetter(address)
  ac.addBalance(address, 1.u256)


proc runTrial2ok(vmState: BaseVMState; inx: int) =
  ## Run two blocks, the first one with *rollback*.
  let eAddr = txs[inx].getSender

  block:
    let accTx = vmState.stateDB.beginSavepoint
    vmState.stateDB.modBalance(eAddr)
    vmState.stateDB.rollback(accTx)

  block:
    let accTx = vmState.stateDB.beginSavepoint
    vmState.stateDB.modBalance(eAddr)
    vmState.stateDB.commit(accTx)

  vmState.stateDB.persist(clearCache = false)


proc runTrial3(vmState: BaseVMState; inx: int; rollback: bool) =
  ## Run three blocks, the second one optionally with *rollback*.
  let eAddr = txs[inx].getSender

  block:
    let accTx = vmState.stateDB.beginSavepoint
    vmState.stateDB.modBalance(eAddr)
    vmState.stateDB.commit(accTx)
    vmState.stateDB.persist(clearCache = false)

  block:
    let accTx = vmState.stateDB.beginSavepoint
    vmState.stateDB.modBalance(eAddr)

    if rollback:
      vmState.stateDB.rollback(accTx)
      break

    vmState.stateDB.commit(accTx)
    vmState.stateDB.persist(clearCache = false)

  block:
    let accTx = vmState.stateDB.beginSavepoint
    vmState.stateDB.modBalance(eAddr)
    vmState.stateDB.commit(accTx)
    vmState.stateDB.persist(clearCache = false)


proc runTrial3crash(vmState: BaseVMState; inx: int; noisy = false) =
  ## Run three blocks with extra db frames and *rollback*.
  let eAddr = txs[inx].getSender

  block:
    let dbTx = xdb.beginTransaction()

    block:
      let accTx = vmState.stateDB.beginSavepoint
      vmState.stateDB.modBalance(eAddr)
      vmState.stateDB.commit(accTx)
      vmState.stateDB.persist(clearCache = false)

    block:
      let accTx = vmState.stateDB.beginSavepoint
      vmState.stateDB.modBalance(eAddr)
      vmState.stateDB.rollback(accTx)

    # The following statement will cause a crash at the next `persist()` call.
    dbTx.rollback()

  # In order to survive without an exception in the next `persist()` call, the
  # following function could be added to db/accounts_cache.nim:
  #
  #   proc clobberRootHash*(ac: AccountsCache; root: KeccakHash; prune = true) =
  #     ac.trie = initAccountsTrie(ac.db, rootHash, prune)
  #
  # Then, beginning this very function `runTrial3crash()` with
  #
  #   let stateRoot = vmState.stateDB.rootHash
  #
  # the survival statement would be to re-assign the state-root via
  #
  #   vmState.stateDB.clobberRootHash(stateRoot)
  #
  # Also mind this comment from Andri:
  #
  #   [..] but as a reminder, only reinit the ac.trie is not enough, you
  #   should consider the accounts in the cache too. if there is any accounts
  #   in the cache they must in sync with the new rootHash.
  #
  block:
    let dbTx = xdb.beginTransaction()

    block:
      let accTx = vmState.stateDB.beginSavepoint
      vmState.stateDB.modBalance(eAddr)
      vmState.stateDB.commit(accTx)

      try:
        vmState.stateDB.persist(clearCache = false)
      except AssertionDefect as e:
        if noisy:
          let msg = e.msg.rsplit($DirSep,1)[^1]
          echo &"*** runVmExec({eAddr.pp}): {e.name}: {msg}"
        dbTx.dispose()
        raise e

      vmState.stateDB.persist(clearCache = false)

    dbTx.commit()


proc runTrial4(vmState: BaseVMState; inx: int; rollback: bool) =
  ## Like `runTrial3()` but with four blocks and extra db transaction frames.
  let eAddr = txs[inx].getSender

  block:
    let dbTx = xdb.beginTransaction()

    block:
      let accTx = vmState.stateDB.beginSavepoint
      vmState.stateDB.modBalance(eAddr)
      vmState.stateDB.commit(accTx)
      vmState.stateDB.persist(clearCache = false)

    block:
      let accTx = vmState.stateDB.beginSavepoint
      vmState.stateDB.modBalance(eAddr)
      vmState.stateDB.commit(accTx)
      vmState.stateDB.persist(clearCache = false)

    block:
      let accTx = vmState.stateDB.beginSavepoint
      vmState.stateDB.modBalance(eAddr)

      if rollback:
        vmState.stateDB.rollback(accTx)
        break

      vmState.stateDB.commit(accTx)
      vmState.stateDB.persist(clearCache = false)

    # There must be no dbTx.rollback() here unless `vmState.stateDB` is
    # discarded and/or re-initialised.
    dbTx.commit()

  block:
    let dbTx = xdb.beginTransaction()

    block:
      let accTx = vmState.stateDB.beginSavepoint
      vmState.stateDB.modBalance(eAddr)
      vmState.stateDB.commit(accTx)
      vmState.stateDB.persist(clearCache = false)

    dbTx.commit()

# ------------------------------------------------------------------------------
# Test Runner
# ------------------------------------------------------------------------------

proc runner(noisy = true; capture = goerliCapture) =
  let
    loadBlocks = capture.numBlocks.u256
    loadTxs = capture.numTxs
    fileInfo = capture.file.splitFile.name.split(".")[0]
    filePath = capture.file.findFilePath
    com = capture.network.blockChainForTesting

  txs.reset
  xdb = com.db

  suite &"StateDB nesting scenarios":
    var topNumber: BlockNumber

    test &"Import from {fileInfo}":
      # Import minimum amount of blocks, then collect transactions
      for chain in filePath.undumpBlocks:
        let leadBlkNum = chain[0][0].blockNumber
        topNumber = chain[0][^1].blockNumber

        if loadTxs <= txs.len:
          break

        # Verify Genesis
        if leadBlkNum == 0.u256:
          doAssert chain[0][0] == xdb.getBlockHeader(0.u256)
          continue

        # Import block chain blocks
        if leadBlkNum < loadBlocks:
          com.importBlocks(chain[0],chain[1])
          continue

        # Import transactions
        for inx in 0 ..< chain[0].len:
          let blkTxs = chain[1][inx].transactions

          # Continue importing up until first non-trivial block
          if txs.len == 0 and blkTxs.len == 0:
            com.importBlocks(@[chain[0][inx]],@[chain[1][inx]])
            continue

          # Load transactions
          txs.add blkTxs


    test &"Collect unique sender addresses from {txs.len} txs," &
        &" head=#{xdb.getCanonicalHead.blockNumber}, top=#{topNumber}":
      var seen: Table[EthAddress,bool]
      for n,tx in txs:
        let a = tx.getSender
        if not seen.hasKey(a):
          seen[a] = true
          txi.add n

    test &"Run {txi.len} two-step trials with rollback":
      let dbTx = xdb.beginTransaction()
      defer: dbTx.dispose()
      for n in txi:
        let vmState = com.getVmState(xdb.getCanonicalHead.blockNumber)
        vmState.runTrial2ok(n)

    test &"Run {txi.len} three-step trials with rollback":
      let dbTx = xdb.beginTransaction()
      defer: dbTx.dispose()
      for n in txi:
        let vmState = com.getVmState(xdb.getCanonicalHead.blockNumber)
        vmState.runTrial3(n, rollback = true)

    test &"Run {txi.len} three-step trials with extra db frame rollback" &
        " throwing Exceptions":
      let dbTx = xdb.beginTransaction()
      defer: dbTx.dispose()
      for n in txi:
        let vmState = com.getVmState(xdb.getCanonicalHead.blockNumber)
        expect AssertionDefect:
          vmState.runTrial3crash(n, noisy)

    test &"Run {txi.len} tree-step trials without rollback":
      let dbTx = xdb.beginTransaction()
      defer: dbTx.dispose()
      for n in txi:
        let vmState = com.getVmState(xdb.getCanonicalHead.blockNumber)
        vmState.runTrial3(n, rollback = false)

    test &"Run {txi.len} four-step trials with rollback and db frames":
      let dbTx = xdb.beginTransaction()
      defer: dbTx.dispose()
      for n in txi:
        let vmState = com.getVmState(xdb.getCanonicalHead.blockNumber)
        vmState.runTrial4(n, rollback = true)

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc accountsCacheMain*(noisy = defined(debug)) =
  noisy.runner

when isMainModule:
  var noisy = defined(debug)
  #noisy = true

  setErrorLevel()
  noisy.runner # mainCapture
  # noisy.runner goerliCapture2

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
