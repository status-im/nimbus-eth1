# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Tasklets: Packer, VM execute and compact txs
## =============================================================
##

import
  std/[sets, tables],
  ../../../db/[accounts_cache, db_chain],
  ../../../forks,
  ../../../p2p/[dao, executor],
  ../../../transaction/call_evm,
  ../../../vm_state,
  ../../../vm_types,
  ../tx_chain,
  ../tx_desc,
  ../tx_item,
  ../tx_tabs,
  ../tx_tabs/tx_status,
  ./tx_bucket,
  ./tx_classify,
  chronicles,
  eth/[common, keys, rlp, trie, trie/db],
  stew/[sorted_set]

{.push raises: [Defect].}

type
  TxPackerError* = object of CatchableError
    ## Catch and relay exception error

  TxPackerStateRef = ref object
    xp: TxPoolRef
    tr: HexaryTrie
    vmState: BaseVMState
    stop: bool

const
  receiptsExtensionSize = ##\
    ## Number of items to extend the `receipts[]` sequence with.
    20

logScope:
  topics = "tx-pool packer"

# [
# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

import std/[sequtils, strutils]

proc pp(a: EthAddress): string =
  a.mapIt(it.toHex(2)).join[12 .. 19].toLowerAscii

const statusInfo = block:
  var rc: array[TxItemStatus,string]
  rc[txItemPending] = "*"
  rc[txItemStaged] = "S"
  rc[txItemPacked] = "P"
  rc

proc pp(item: TxItemRef): string =
  if item.isNil:
    return "nil"
  "(" & statusInfo[item.status] &
    "," & item.sender.pp &
    "," & $item.tx.nonce &
    ")"

template say(args: varargs[untyped]): untyped =
  # echo "*** ", args
  discard

#]#

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template safeExecutor(info: string; code: untyped) =
  try:
    code
  except CatchableError as e:
    raise (ref CatchableError)(msg: e.msg)
  except Defect as e:
    raise (ref Defect)(msg: e.msg)
  except:
    let e = getCurrentException()
    raise newException(TxPackerError, info & "(): " & $e.name & " -- " & e.msg)

proc gasBurned(pst: TxPackerStateRef): GasInt =
  ## To be used instead of `vmState.cumulativeGasUsed` which is ignored as the
  ## same value is available as `vmState.receipts[inx-1].cumulativeGasUsed`.
  ## This makes it handy for transparently picking up after a rollback.
  let inx = pst.xp.txDB.byStatus.eq(txItemPacked).nItems
  if 0 < inx:
    result = pst.vmState.receipts[inx-1].cumulativeGasUsed

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc runTx(pst: TxPackerStateRef; item: TxItemRef): GasInt
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Execute item transaction and update `vmState` book keeping. Returns the
  ## `gasUsed` after executing the transaction.
  safeExecutor "tx_packer.runTx":
    # Execute transaction, may return a wildcard `Exception`
    result = item.tx.txCallEvm(item.sender, pst.vmState, pst.xp.chain.nextFork)
  doAssert 0 <= result

proc runTxCommit(pst: TxPackerStateRef; item: TxItemRef; gasBurned: GasInt)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Book keeping after executing argument `item` transaction in the VM. The
  ## function returns the next number of items `nItems+1`.
  let
    xp = pst.xp
    vmState = pst.vmState
    inx = xp.txDB.byStatus.eq(txItemPacked).nItems
    gasTip = item.tx.effectiveGasTip(xp.chain.head.baseFee)

  # The gas tip cannot get negative as all items in the `staged` bucket
  # are vetted for profitability before entering that bucket.
  assert 0 <= gasTip
  vmState.stateDB.addBalance(xp.chain.miner, (gasBurned * gasTip).uint64.u256)

  # Update account database
  vmState.mutateStateDB:
    for deletedAccount in vmState.selfDestructs:
      db.deleteAccount deletedAccount

    if FkSpurious <= xp.chain.nextFork:
      vmState.touchedAccounts.incl(xp.chain.miner)
      # EIP158/161 state clearing
      for account in vmState.touchedAccounts:
        if db.accountExists(account) and db.isEmptyAccount(account):
          debug "state clearing", account
          db.deleteAccount account

  if vmState.generateWitness:
    vmState.stateDB.collectWitnessData()

  # Commit accounts
  vmState.stateDB.persist(clearCache = false)

  # Update receipts sequence
  if vmState.receipts.len <= inx:
    vmState.receipts.setLen(inx + receiptsExtensionSize)

  vmState.cumulativeGasUsed = pst.gasBurned + gasBurned
  vmState.receipts[inx] = vmState.makeReceipt(item.tx.txType)

  # Update txRoot
  pst.tr.put(rlp.encode(inx), rlp.encode(item.tx))

  # Add the item to the `packed` bucket. This implicitely increases the
  # receipts index `inx` at the next visit of this function.
  discard xp.txDB.reassign(item,txItemPacked)

# ------------------------------------------------------------------------------
# Private functions: packer loop
# ------------------------------------------------------------------------------

#[
proc collectAccount(pst: TxPackerStateRef; nonceList: TxStatusNonceRef): bool
    {.gcsafe,raises: [Defect,CatchableError].}  =
  ## Make sure that the full account list goes into the block. Otherwise
  ## proceed with per-item transaction/step-wise mode, below.
  let dbTx = pst.xp.chain.db.db.beginTransaction

  # Keep a list of items added. It will be used either for rollback,
  # or for the account-wise update of the txRoot.
  var
    allFuel = 0.GasInt
    topOfList = 0
    itemList = newSeq[TxItemRef](nonceList.len)

  # Collect items and pack
  for item in nonceList.incNonce:
    let
      accTx = pst.vmState.stateDB.beginSavepoint
      totalGas = pst.gasBurned
      gasUsed = pst.runTx(item)

    if not pst.xp.classifyPacked(totalGas, gasUsed):
      # Roll back databases
      pst.vmState.stateDB.rollback(accTx)
      dbTx.rollback()

      # Undo collecting items for this account
      for n in 0 ..< topOfList:
        discard pst.xp.txDB.reassign(itemList[n],txItemStaged)
      say "collectAccount",
        " item[", topOfList, "] too big ", item.pp,
        " size=", totalGas, "+", gasUsed,
        " => rollback"
      return false

    # Commit account state DB
    pst.vmState.stateDB.commit(accTx)

    # Finish book-keeping and move item to `packed` bucket
    pst.runTxCommit(item, gasUsed)
    say "collectAccount", " item", item.pp, " => accepted"

    # Locally accumulate total gas
    allFuel += gasUsed

    # Collect item for post-processing and/or rollback
    itemList[topOfList] = item
    topOfList.inc

  # Accept account items
  dbTx.commit

  say "collectAccount",
    " ", itemList[0].sender.pp,
    " baseFee=", pst.xp.chain.head.baseFee,
    " len=", itemList.len, " => OK"
  true
#]#

proc collectItem(pst: TxPackerStateRef; item: TxItemRef): bool
    {.gcsafe,raises: [Defect,CatchableError].}  =
  ## Collect single item in its own transaction frame.
  ##
  ## if the return code is `false`, the descriptor variable `pst.stop` is
  ## reset to `false` as a suggestion to continue packing the next account,
  ## and `true` for termination.
  let
    xp = pst.xp
    vmState = pst.vmState

  let dbTx = xp.chain.db.db.beginTransaction
  defer: dbTx.dispose

  let accTx = vmState.stateDB.beginSavepoint
  defer: vmState.stateDB.dispose(accTx)

  let
    totalGas = pst.gasBurned
    gasUsed = pst.runTx(item)
  if not xp.classifyPacked(totalGas, gasUsed):
    pst.stop = not xp.classifyPackedNext(totalGas, gasUsed)
    # otherwise rollback, and stop
    return false

  # Commit account state DB
  vmState.stateDB.commit(accTx)

  # Finish book-keeping and move item to `packed` bucket
  pst.runTxCommit(item, gasUsed)

  # Accept single item
  dbTx.commit
  true


proc packerLoop(pst: TxPackerStateRef)
    {.gcsafe,raises: [Defect,CatchableError].}  =
  ## Greedily compact items as long as the accumulated `gasLimit` values
  ## are below the block size

  # Flush `packed` bucket
  pst.xp.bucketFlushPacked

  # Select items and move them to the `packed` bucket
  for (account,nonceList) in pst.xp.txDB.decAccount(txItemStaged):

    #[
    # For the given account, try to execute all items of this account
    # within a single transaction frame.
    #
    # say "packerVmExec account=", account.pp
    if pst.collectAccount(nonceList):
      continue
    #]#

    # Otherwise execute items individually, each one within its own
    # transaction frame.
    for item in nonceList.incNonce:
      say "packerVmExec item=", item.pp
      if not pst.collectItem(item):
        if pst.stop:
          return
        # stop inner loop and continue with next account
        break

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc packerVmExec*(xp: TxPoolRef) {.gcsafe,raises: [Defect,CatchableError].} =
  ## Rebuild `packed` bucket by selection items from the `staged` bucket
  ## after executing them in the VM.
  let dbTx = xp.chain.db.db.beginTransaction
  defer: dbTx.dispose()

  # Internal descriptor
  var pst = TxPackerStateRef(
    xp: xp,
    tr: newMemoryDB().initHexaryTrie,
    vmState: xp.chain.getVmState)

  let
    nextBlockNum = xp.chain.head.blockNumber + 1
    preBalance = pst.vmState.readOnlyStateDB.getBalance(xp.chain.miner)

  if xp.chain.config.daoForkSupport and
     xp.chain.config.daoForkBlock == nextBlockNum:
    pst.vmState.mutateStateDB:
      db.applyDAOHardFork()

  # Rebuild  `packed` bucket
  pst.packerLoop

  # Update flexi-arrays, set proper length
  let nItems = xp.txDB.byStatus.eq(txItemPacked).nItems
  pst.vmState.receipts.setLen(nItems)

  xp.chain.receipts = pst.vmState.receipts
  xp.chain.txRoot = pst.tr.rootHash

  proc balanceDelta: Uint256 =
    let postBalance = pst.vmState.readOnlyStateDB.getBalance(xp.chain.miner)
    if preBalance < postBalance:
      return postBalance - preBalance

  xp.chain.profit = balanceDelta()

  if not pst.vmState.chainDB.config.poaEngine:
    # @[]: no uncles yet
    pst.vmState.calculateReward(xp.chain.miner, nextBlockNum, @[])

  xp.chain.reward = balanceDelta()

  #  # The following is not needed as the block chain is rolled back, anyway
  #
  #  # Reward beneficiary
  #  vmState.mutateStateDB:
  #   if vmState.generateWitness:
  #     db.collectWitnessData()
  #   db.persist(ClearCache in vmState.flags)

  # Block chain will roll back automatically

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
