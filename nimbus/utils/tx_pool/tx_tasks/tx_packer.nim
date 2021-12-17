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
  ../../../p2p/[dao, executor, validate],
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
    cleanState: bool

const
  receiptsExtensionSize = ##\
    ## Number of slots to extend the `receipts[]` at the same time.
    20

logScope:
  topics = "tx-pool packer"

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

proc eip1559TxNormalization(tx: Transaction): Transaction =
  result = tx
  if tx.txType < TxEip1559:
    result.maxPriorityFee = tx.gasPrice
    result.maxFee = tx.gasPrice

proc persist(pst: TxPackerStateRef)
    {.gcsafe,raises: [Defect,RlpError].} =
  ## Smart wrapper
  if not pst.cleanState:
    pst.vmState.stateDB.persist(clearCache = false)
    pst.cleanState = true

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc runTx(pst: TxPackerStateRef; item: TxItemRef): GasInt
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Execute item transaction and update `vmState` book keeping. Returns the
  ## `gasUsed` after executing the transaction.
  var
    tx = item.tx.eip1559TxNormalization
  let
    fork = pst.xp.chain.nextFork
    baseFee = pst.xp.chain.head.baseFee
  if FkLondon <= fork:
    tx.gasPrice = min(tx.maxPriorityFee + baseFee.truncate(int64), tx.maxFee)

  safeExecutor "tx_packer.runTx":
    # Execute transaction, may return a wildcard `Exception`
    result = tx.txCallEvm(item.sender, pst.vmState, fork)

  pst.cleanState = false
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
  let reward = gasBurned.u256 * gasTip.uint64.u256
  vmState.stateDB.addBalance(xp.chain.miner, reward)

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

  # Save accounts via persist() is not needed unless the fork is smaller
  # than `FkByzantium` in which case, the `rootHash()` function is called
  # by `makeReceipt()`. As the `rootHash()` function asserts unconditionally
  # that the account cache has been saved, the `persist()` call is
  # obligatory here.
  if xp.chain.nextFork < FkByzantium:
    pst.persist

  # Update receipts sequence
  if vmState.receipts.len <= inx:
    vmState.receipts.setLen(inx + receiptsExtensionSize)

  # vmState.cumulativeGasUsed = pst.gasBurned + gasBurned
  vmState.cumulativeGasUsed += gasBurned
  vmState.receipts[inx] = vmState.makeReceipt(item.tx.txType)

  # Update txRoot
  pst.tr.put(rlp.encode(inx), rlp.encode(item.tx))

  # Add the item to the `packed` bucket. This implicitely increases the
  # receipts index `inx` at the next visit of this function.
  discard xp.txDB.reassign(item,txItemPacked)

# ------------------------------------------------------------------------------
# Private functions: packer loop
# ------------------------------------------------------------------------------

proc packerLoop(pst: TxPackerStateRef)
    {.gcsafe,raises: [Defect,CatchableError].}  =
  ## Greedily compact items as long as the accumulated `gasLimit` values
  ## are below the block size
  let
    xp = pst.xp
    vmState = pst.vmState

  # Flush `packed` bucket
  xp.bucketFlushPacked

  # Select items and move them to the `packed` bucket
  for (_,nonceList) in pst.xp.txDB.decAccount(txItemStaged):
    for item in nonceList.incNonce:

      # Validate transaction relative to the current vmState
      if not xp.classifyValidatePacked(vmState, item):
        break # continue with next account

      let
        accTx = vmState.stateDB.beginSavepoint
        gasUsed = pst.runTx(item)

      # Find out what to do next: accepting this tx or trying the next account
      if not xp.classifyPacked(vmState.cumulativeGasUsed, gasUsed):
        vmState.stateDB.rollback(accTx)
        if xp.classifyPackedNext(vmState.cumulativeGasUsed, gasUsed):
          break # continue with next account
        return  # stop

      # Commit account state DB
      vmState.stateDB.commit(accTx)

      vmState.stateDB.persist(clearCache = false)
      let midRoot = vmState.stateDB.rootHash

      # Finish book-keeping and move item to `packed` bucket
      pst.runTxCommit(item, gasUsed)

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
  pst.persist

  # Update flexi-array, set proper length
  let nItems = xp.txDB.byStatus.eq(txItemPacked).nItems
  pst.vmState.receipts.setLen(nItems)

  xp.chain.receipts = pst.vmState.receipts
  xp.chain.txRoot = pst.tr.rootHash
  xp.chain.stateRoot = pst.vmState.stateDB.rootHash

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
