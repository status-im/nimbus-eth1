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
  std/[os, sequtils, strformat, strutils],
  ../nimbus/[chain_config, config, constants, genesis],
  ../nimbus/db/[accounts_cache, db_chain],
  #not-needed# ../nimbus/forks,
  ../nimbus/p2p/chain,
  #not-needed# ../nimbus/p2p/[dao, executor],
  ../nimbus/transaction,
  ../nimbus/transaction/call_evm,
  ../nimbus/vm_state,
  ../nimbus/vm_types,
  ./test_clique/undump,
  eth/[common, keys, p2p, trie/db],
  stint,
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
    numBlocks: 22000,  # unconditionally load blocks
    numTxs:       30)  # txs following (not in block chain)

  # example from clique, signer: 658bdf435d810c91414ec09147daa6db62406379
  prvKey = "9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"

  #not-needed# baseFee = 0

  # txs[] index triples, shoud be within `numTxs` range :)
  samples = [
    (10, 2, 0),
    ( 1, 2, 3),
    ( 7, 7, 7),
  ]

let
  prvTestKey* = PrivateKey.fromHex(prvKey).value
  pubTestKey* = prvTestKey.toPublicKey
  testAddress* = pubTestKey.toCanonicalAddress

var
  xdb: BaseChainDB
  txs: seq[Transaction]

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
  a.mapIt(it.toHex(2)).join[12 .. 19].toLowerAscii

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

proc effectiveGasTip(tx: Transaction; baseFee: int64): int64 =
  if tx.txType == TxLegacy:
    tx.gasPrice - baseFee
  else:
    # London, EIP1559
    min(tx.maxPriorityFee, tx.maxFee - baseFee)

# ------------------------------------------------------------------------------
# Test function for finding out about the transaction framework
# ------------------------------------------------------------------------------

#[
proc runVmExec(vmState: BaseVMState;
               batch: openArray[(Transaction,bool)]; noisy = false) =
  ## This function causes the stateDB to crash depending on function arguments.
  ## This is the general example.
  let
    miner = testAddress
    nextBlockNum = vmState.blockHeader.blockNumber + 1
    fork = xdb.config.toFork(nextBlockNum)

  #not-needed# if xdb.config.daoForkSupport and
  #not-needed#    xdb.config.daoForkBlock == nextBlockNum:
  #not-needed#   vmState.mutateStateDB:
  #not-needed#     db.applyDAOHardFork()

  let dbTx = xdb.db.beginTransaction()
  defer: dbTx.dispose()

  for (tx,accOk) in batch.items:
    let accTx = vmState.stateDB.beginSavepoint
    defer: vmState.stateDB.dispose(accTx)

    let
      sender = tx.getSender
      gasBurned = tx.txCallEvm(sender, vmState, fork)

    if not accOK:
      if noisy and 1 < batch.len:
        let n = 1 + tx.nonce - batch[0][0].nonce
        echo &"*** runVmExec tx={tx.pp} => reject {n}-nd/th instance"
      # implies deferred dispose directives
      return

    vmState.stateDB.commit(accTx)

    #not-needed# # Update accounts database
    #not-needed# let gasTip = tx.effectiveGasTip(baseFee)
    #not-needed# vmState.stateDB.addBalance(miner, (gasBurned * gasTip).u256)
    #not-needed#
    #not-needed# vmState.mutateStateDB:
    #not-needed#   for deletedAccount in vmState.selfDestructs:
    #not-needed#     db.deleteAccount deletedAccount
    #not-needed#
    #not-needed#   if FkSpurious <= fork:
    #not-needed#     vmState.touchedAccounts.incl(miner)
    #not-needed#     # EIP158/161 state clearing
    #not-needed#     for account in vmState.touchedAccounts:
    #not-needed#       if db.accountExists(account) and
    #not-needed#          db.isEmptyAccount(account):
    #not-needed#         debug "state clearing", account
    #not-needed#         db.deleteAccount account
    #not-needed#
    #not-needed# if vmState.generateWitness:
    #not-needed#   vmState.stateDB.collectWitnessData()

    # Function crashes here (if at all)
    try:
      vmState.stateDB.persist(clearCache = false)
    except AssertionError as e:
      if noisy:
        echo &"*** runVmExec tx={tx.pp}",
          &" => {e.name}: {e.msg.rsplit($DirSep,1)[^1]}"
      raise e

    #not-needed# vmState.cumulativeGasUsed += gasBurned
    #not-needed# vmState.receipts.add vmState.makeReceipt(tx.txType)

  dbTx.commit()
#]#

# ----------

proc runVmExec(vmState: BaseVMState;
               tx: Transaction; accOk: bool; noisy = false) =
  ## Shortcut for `vmState.runVmExec([(tx,accOk)])`
  let
    nextBlockNum = vmState.blockHeader.blockNumber + 1
    fork = xdb.config.toFork(nextBlockNum)

    dbTx = xdb.db.beginTransaction()
    accTx = vmState.stateDB.beginSavepoint

    sender = tx.getSender
    gasBurned = tx.txCallEvm(sender, vmState, fork)

  if not accOK:
    vmState.stateDB.rollback(accTx)
    dbTx.rollback()
    return

  vmState.stateDB.commit(accTx)

  # Function crashes here (if at all)
  try:
    vmState.stateDB.persist(clearCache = false)
  except AssertionError as e:
    if noisy: echo &"*** runVmExec tx={tx.pp}",
        &" => {e.name}: {e.msg.rsplit($DirSep,1)[^1]}"
    dbTx.dispose()
    raise e

  dbTx.commit()


proc runVmExec(vmState: BaseVMState;
               tx1, tx2: Transaction; accOk: bool; noisy = false) =
  ## Shortcut for `vmState.runVmExec([(tx1,true),(tx2,false)])`
  let
    nextBlockNum = vmState.blockHeader.blockNumber + 1
    fork = xdb.config.toFork(nextBlockNum)

    dbTx = xdb.db.beginTransaction()

  block:
    let
      accTx = vmState.stateDB.beginSavepoint
      sender = tx1.getSender
      gasBurned = tx1.txCallEvm(sender, vmState, fork)

    vmState.stateDB.commit(accTx)
    vmState.stateDB.persist(clearCache = false)

  block:
    let
      accTx = vmState.stateDB.beginSavepoint
      sender = tx2.getSender
      gasBurned = tx2.txCallEvm(sender, vmState, fork)

    if not accOK:
      if noisy: echo &"*** runVmExec tx={tx2.pp} => reject 2-nd instance"
      vmState.stateDB.rollback(accTx)
      dbTx.rollback()
      return

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

  txs.reset
  xdb = capture.network.blockChainForTesting

  suite &"StateDB crash scenario as seen by TxPool":

    test &"Import from {fileInfo}":

      # Import minimum amount of blocks, then collect transactions
      for chain in filePath.undumpNextGroup:
        let leadBlkNum = chain[0][0].blockNumber

        if loadTxs <= txs.len:
          break

        if leadBlkNum == 0.u256:
          # Verify Genesis
          doAssert chain[0][0] == xdb.getBlockHeader(0.u256)
          continue

        if leadBlkNum < loadBlocks:
          # import block chain
          xdb.importBlocks(chain[0],chain[1])
          continue

        # Import transactions
        for inx in 0 ..< chain[0].len:
          let blkTxs = chain[1][inx].transactions

          # Continue importing up until first non-trivial block
          if txs.len == 0 and blkTxs.len == 0:
            xdb.importBlocks(@[chain[0][inx]],@[chain[1][inx]])
            continue

          # Load transactions
          txs.add blkTxs

      if noisy:
        echo &"*** runner #{xdb.getCanonicalHead.blockNumber} txs={txs.len}"


    test "Exec single stepped sets of txs with rollback":
      for (a,b,c) in samples:
        let dbTx = xdb.db.beginTransaction()
        defer: dbTx.dispose()

        let vmState = xdb.getVmState(xdb.getCanonicalHead.blockNumber)
        vmState.runVmExec(txs[a], true, noisy)
        vmState.runVmExec(txs[b], false, noisy)
        vmState.runVmExec(txs[c], true, noisy)


    test "Exec grouped txs sets with rollback (throwing Assertion exceptions)":
      # Cosmetics ...
      if noisy:
        echo ""

      for (a,b,c) in samples:
        let dbTx = xdb.db.beginTransaction()
        defer: dbTx.dispose()

        let vmState = xdb.getVmState(xdb.getCanonicalHead.blockNumber)
        vmState.runVmExec(txs[a], txs[b], false, noisy)

        expect AssertionError:
          vmState.runVmExec(txs[c], true, noisy)


    test "Exec grouped txs sets without rollback (no exceptions)":
      for (a,b,c) in samples:
        let dbTx = xdb.db.beginTransaction()
        defer: dbTx.dispose()

        let vmState = xdb.getVmState(xdb.getCanonicalHead.blockNumber)
        vmState.runVmExec(txs[a], txs[b], true, noisy)
        vmState.runVmExec(txs[c], true, noisy)

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc txCrashMain*(noisy = defined(debug)) =
  noisy.runner

when isMainModule:
  var noisy = defined(debug)
  noisy = true

  noisy.runner

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
