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
  std/[os, sequtils, strformat, strutils, tables],
  ../nimbus/[chain_config, config, constants, genesis],
  ../nimbus/db/[accounts_cache, db_chain],
  ../nimbus/p2p/chain,
  ../nimbus/transaction,
  ../nimbus/vm_state,
  ../nimbus/vm_types,
  ./test_clique/undump,
  eth/[common, p2p, trie/db],
  unittest2

type
  CaptureSpecs = tuple
    network: NetworkID
    file: string
    numBlocks: int
    numTxs: int

const
  baseDir = [".", "tests", ".." / "tests", $DirSep] # path containg repo
  repoDir = ["replay", "status", "test_clique"]     # alternative repo paths

  goerliCapture: CaptureSpecs = (
    network: GoerliNet,
    # file: "goerli68161.txt.gz",
    file: "goerli51840.txt.gz",
    numBlocks: 5500,  # unconditionally load blocks
    numTxs:      10)  # txs following (not in block chain)

var
  xdb: BaseChainDB
  txs: seq[Transaction]
  txi: seq[int] # index into txs[] with usable sender adresses

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

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc blockChainForTesting*(network: NetworkID): BaseChainDB =
  result = newBaseChainDB(
    newMemoryDb(),
    id = network,
    params = network.networkParams)
  result.populateProgress
  initializeEmptyDB(result)

proc importBlocks(cdb: BaseChainDB; h: seq[BlockHeader]; b: seq[BlockBody]) =
  if cdb.newChain.persistBlocks(h,b) != ValidationResult.OK:
    raiseAssert "persistBlocks() failed at block #" & $h[0].blockNumber

proc getVmState(cdb: BaseChainDB; number: BlockNumber): BaseVMState =
  let
    topHeader = cdb.getBlockHeader(number)
    accounts = AccountsCache.init(cdb.db, topHeader.stateRoot, cdb.pruneTrie)
  result = accounts.newBaseVMState(topHeader, cdb)

# ------------------------------------------------------------------------------
# Crash test function, finding out about how the transaction framework works ..
# ------------------------------------------------------------------------------

proc modBalance(ac: var AccountsCache, address: EthAddress) =
  ## This function is crucial for profucing the crash. If must
  ## modify the balance so that the database gets written.
  # ac.blindBalanceSetter(address)
  ac.addBalance(address, 1.u256)

proc runStateDbTrial(vmState: BaseVMState;
                     eAddr: EthAddress; rollbackOk: bool; noisy = false) =
  ## Run three blocks, the second one optionally with *rollback*.
  block firstPairOfBlocks:
    let dbTx = xdb.db.beginTransaction()

    # First sub-block pair => commit
    block:
      let
        accTx1 = vmState.stateDB.beginSavepoint
        accTx2 = vmState.stateDB.beginSavepoint
      vmState.stateDB.modBalance(eAddr)
      vmState.stateDB.commit(accTx2)
      vmState.stateDB.commit(accTx1)

    vmState.stateDB.persist(clearCache = false)

    # Second sub-block pair => rollback
    block:
      let
        accTx1 = vmState.stateDB.beginSavepoint
        accTx2 = vmState.stateDB.beginSavepoint
      vmState.stateDB.modBalance(eAddr)
      vmState.stateDB.commit(accTx2)

      if rollbackOk:
        vmState.stateDB.rollback(accTx1)
        dbTx.rollback()
        break firstPairOfBlocks

      vmState.stateDB.commit(accTx1)

    vmState.stateDB.persist(clearCache = false)
    dbTx.commit()

  block thirdBlock:
    let dbTx = xdb.db.beginTransaction()

    # Block following => commit
    block:
      let
        accTx1 = vmState.stateDB.beginSavepoint
        accTx2 = vmState.stateDB.beginSavepoint
      vmState.stateDB.modBalance(eAddr)
      vmState.stateDB.commit(accTx2)
      vmState.stateDB.commit(accTx1)

    # Function crashes here (if at all)
    try:
      vmState.stateDB.persist(clearCache = false)
    except AssertionError as e:
      if noisy:
        let msg = e.msg.rsplit($DirSep,1)[^1]
        echo &"*** runVmExec({eAddr.pp}): {e.name}: {msg}"
      dbTx.dispose()
      raise e

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

  txs.reset
  xdb = capture.network.blockChainForTesting

  suite &"StateDB crash scenario as seen by TxPool":

    test &"Import from {fileInfo}":
      var topNumber: BlockNumber

      # Import minimum amount of blocks, then collect transactions
      for chain in filePath.undumpNextGroup:
        let leadBlkNum = chain[0][0].blockNumber
        topNumber = chain[0][^1].blockNumber

        if loadTxs <= txs.len:
          break

        if chain[0][0].blockNumber == 0.u256:
          # Verify Genesis
          doAssert chain[0][0] == xdb.getBlockHeader(0.u256)
          continue

        if leadBlkNum < loadBlocks:
          # import block chain
          xdb.importBlocks(chain[0],chain[1])
          continue

        # Import transactions
        for inx in 0 ..< chain[0].len:
          let
            blkNum = chain[0][inx].blockNumber
            blkTxs = chain[1][inx].transactions

          # Continue importing up until first non-trivial block
          if txs.len == 0 and blkTxs.len == 0:
            xdb.importBlocks(@[chain[0][inx]],@[chain[1][inx]])
            continue

          # Load transactions
          txs.add blkTxs

      if noisy:
        let n = xdb.getCanonicalHead.blockNumber
        echo &"*** Block chain head=#{n} top=#{topNumber} txs={txs.len}"


    test "Collect stateDB crasher addresses":
      var als: Table[EthAddress,bool]
      for n,tx in txs:
        let dbTx = xdb.db.beginTransaction()
        defer: dbTx.dispose()

        let
          vmState = xdb.getVmState(xdb.getCanonicalHead.blockNumber)
          address = tx.getSender

        try:
          vmState.runStateDbTrial(address, rollbackOk = true)
        except:
          if not als.hasKey(address):
            als[address] = true
            txi.add n

      if noisy:
        echo &"*** Found {txi.len} stateDB crasher addresses"


    test &"Run {txi.len} stateDB trials with rollback" &
        " throwing Assertion exceptions":
      check 0 < txi.len

      # makeNoise = true
      # defer: makeNoise = false

      for n in txi:
        let dbTx = xdb.db.beginTransaction()
        defer: dbTx.dispose()

        # Note that this crash scanario works with quite a few addresses
        # different from the ones used here. Using the sender address is
        # just a cheap way to create such tests scenario addresses.

        let
          vmState = xdb.getVmState(xdb.getCanonicalHead.blockNumber)
          testAddr = txs[n].getSender

        expect AssertionError:
          vmState.runStateDbTrial(testAddr, rollbackOk = true, noisy)


    test &"Run {txi.len} stateDB trials without rollback (no exceptions)":
      check 0 < txi.len

      for n in txi:
        let dbTx = xdb.db.beginTransaction()
        defer: dbTx.dispose()

        let
          vmState = xdb.getVmState(xdb.getCanonicalHead.blockNumber)
          testAddr = txs[n].getSender # addr1

        vmState.runStateDbTrial(testAddr, rollbackOk = false, noisy)

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc txCrashMain*(noisy = defined(debug)) =
  noisy.runner

when isMainModule:
  var noisy = defined(debug)
  #noisy = true

  noisy.runner

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
