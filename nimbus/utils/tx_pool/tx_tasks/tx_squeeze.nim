# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Tasklets: Squeezer, VM execute and compact txs
## ===============================================================
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
  eth/[bloom, common, keys, rlp, trie, trie/db],
  stew/[sorted_set]

{.push raises: [Defect].}

type
  TxSqueezeError* = object of CatchableError
    ## Catch and relay exception error

  # TODO: these types need to be removed
  # once eth/bloom and eth/common sync'ed
  # Bloom = common.BloomFilter
  # LogsBloom = bloom.BloomFilter

const
  receiptsExtensionSize = ##\
    ## Number of items to extend the `receipts[]` sequence with.
    20

logScope:
  topics = "tx-pool squeeze"

#[
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
    raise newException(TxSqueezeError, info & "(): " & $e.name & " -- " & e.msg)

proc gasBurned(xp: TxPoolRef; vmState: BaseVMState): GasInt =
  ## To be used instead of `vmState.cumulativeGasUsed` which is ignored as the
  ## same value is available as `vmState.receipts[inx-1].cumulativeGasUsed`.
  ## This makes it handy for transparently picking up after a rollback.
  let inx = xp.txDB.byStatus.eq(txItemPacked).nItems
  if 0 < inx:
    result = vmState.receipts[inx-1].cumulativeGasUsed

proc spaceAvail(xp: TxPoolRef; vmState: BaseVMState; gasUsed: GasInt): bool
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Packing/squeezing constraint for squeezer functions: Continue accumulating
  ## items while this function returns `true`.
  xp.classifySqueezer(xp.gasBurned(vmState) + gasUsed)

#proc continueSqueezing(xp: TxPoolRef; vmState: BaseVMState): bool
#    {.gcsafe,raises: [Defect,CatchableError].} =
#  ## Packing/squeezing constraint for `stagedSqueezer()`: Continue accumulating
#  ## items if this function returns `true`.
#  xp.classifySqueezerTryNext(xp.gasBurned(vmState))

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc runTx(xp: TxPoolRef; vmState: BaseVMState; item: TxItemRef): GasInt
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Execute item transaction and update `vmState` book keeping. Returns the
  ## `gasUsed` after executing the transaction.
  let gasTip = item.tx.effectiveGasTip(xp.chain.head.baseFee)
  if 0.GasPriceEx <= gasTip:
    let
      fork = xp.chain.nextFork
      miner = xp.chain.miner

    # Execute transaction, may return a wildcard `Exception`
    safeExecutor "tx_squeeze.runTx":
      result = item.tx.txCallEvm(item.sender, vmState, fork)

    vmState.stateDB.addBalance(miner, (result * gasTip).uint64.u256)

    # Update account database
    vmState.mutateStateDB:
      for deletedAccount in vmState.selfDestructs:
        db.deleteAccount deletedAccount

      if FkSpurious <= fork:
        vmState.touchedAccounts.incl(miner)
        # EIP158/161 state clearing
        for account in vmState.touchedAccounts:
          if db.accountExists(account) and db.isEmptyAccount(account):
            debug "state clearing", account
            db.deleteAccount(account)

    if vmState.generateWitness:
      vmState.stateDB.collectWitnessData()
      vmState.stateDB.persist(clearCache = false)


proc runTxFinish(xp: TxPoolRef;
                 vmState: BaseVMState; item: TxItemRef; gasBurned: GasInt): bool
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Book keeping after executing argument `item` transaction in the VM. The
  ## function returns the next number of items `nItems+1`.
  let inx = xp.txDB.byStatus.eq(txItemPacked).nItems
  var receipt: Receipt

  # Update receipt, see `p2p/executor/executor_helper.makeReceipt()`
  if xp.chain.nextFork < FkByzantium:
    receipt.isHash = true
    receipt.hash = vmState.stateDB.rootHash
  else:
    receipt.isHash = false
    receipt.status = vmState.status

  # copied from `p2p/executor/executor_helper.makeReceipt()`
  func logsBloom(logs: openArray[Log]): bloom.BloomFilter =
    for log in logs:
      result.incl log.address
      for topic in log.topics:
        result.incl topic

  receipt.receiptType = item.tx.txType
  receipt.cumulativeGasUsed = xp.gasBurned(vmState) + gasBurned
  receipt.logs = vmState.getAndClearLogEntries()
  receipt.bloom = logsBloom(receipt.logs).value.toByteArrayBE

  # Update receipts sequence
  if vmState.receipts.len <= inx:
    vmState.receipts.setLen(inx + receiptsExtensionSize)
  vmState.receipts[inx] = receipt

  # Add the item to the `packed` bucket. This implicitely increases the
  # receipts index `inx` at the next visit of this function.
  xp.txDB.reassign(item,txItemPacked)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc squeezeVmExec*(xp: TxPoolRef) {.gcsafe,raises: [Defect,CatchableError].} =
  ## Execute all transactios of the items in the `packed` bucket in the VM and
  ## compact them for ethernet block inclusion (updateing `vmState` etc.) Then
  ## compact some more from the `staged` bucket if possible. The function
  ## returns the list of compacted items.
  let
    vmState = xp.chain.getVmState
    nextBlockNum = xp.chain.head.blockNumber + 1
    minerBalance = vmState.readOnlyStateDB.getBalance(xp.chain.miner)

  let dbTx = xp.chain.db.db.beginTransaction
  defer: dbTx.dispose()

  if xp.chain.config.daoForkSupport and
     xp.chain.config.daoForkBlock == nextBlockNum:
    vmState.mutateStateDB:
      db.applyDAOHardFork()

  # Internal descriptor
  var tr = newMemoryDB().initHexaryTrie

  # Flush `packed` bucket
  xp.bucketFlushPacked

  # While set `true`, the all items for an account are tried to execute in a
  # single transaction frame before trying single item transaction frames.
  var fullAccountTransactionFirst = true

  # Greedily compact a group of items as long as the accumulated `gasLimit`
  # values are below the block size.
  block allAccounts:
    for (account,nonceList) in xp.txDB.decAccount(txItemStaged):

      if fullAccountTransactionFirst:

        # For the given account, try to execute all items of this account
        # within a single transaction frame.
        block doAccountWise:

          # Make sure that the full account list goes into the block. Otherwise
          # proceed with per-item transaction/step-wise mode, below
          let accountTx = xp.chain.db.db.beginTransaction
          defer: accountTx.dispose

          # Keep a list of items added. It will be used either for rollback,
          # or for the account-wise update of the txRoot.
          var
            aItems = 0
            itemList = newSeq[TxItemRef](nonceList.len)

          for item in nonceList.incNonce:
            let gasBurned = xp.runTx(vmState, item)
            doAssert 0 <= gasBurned

            if not xp.spaceAvail(vmState, gasBurned):
              # Undo collecting items for this account, so far
              for inx in 0 ..< aItems:
                discard xp.txDB.reassign(itemList[inx],txItemStaged)
              # rollback, continue with single step transaction frame
              break doAccountWise

            # Finish book-keeping and move item to `packed` bucket
            discard xp.runTxFinish(vmState, item, gasBurned)

            # Collect item for post-processing and/or rollback
            itemList[aItems] = item
            aItems.inc

          # Accept full group of account items
          accountTx.commit

          # Update txRoot
          let base = xp.txDB.byStatus.eq(txItemPacked).nItems - itemList.len
          for inx,item in itemList.pairs:
            tr.put(rlp.encode(base + inx), rlp.encode(item.tx))

          # Get next account
          continue

      # Execute items individually, each one within its own transaction frame.
      block doItemWise:
        for item in nonceList.incNonce:
          let itemTx = xp.chain.db.db.beginTransaction
          defer: itemTx.dispose

          let gasBurned = xp.runTx(vmState, item)
          doAssert 0 <= gasBurned

          if not xp.spaceAvail(vmState, gasBurned):
            # rollback, continue with next account
            break

          # Finish book-keeping and move item to `packed` bucket
          discard xp.runTxFinish(vmState, item, gasBurned)

          # Accept single item
          itemTx.commit

          # Update txRoot
          let inx = xp.txDB.byStatus.eq(txItemPacked).nItems
          tr.put(rlp.encode(inx - 1), rlp.encode(item.tx))

  # Update flexi-arrays, set proper length
  let nItems = xp.txDB.byStatus.eq(txItemPacked).nItems
  vmState.receipts.setLen(nItems)

  if not vmState.chainDB.config.poaEngine:
    # @[]: no uncles yet
    vmState.calculateReward(xp.chain.miner, nextBlockNum, @[])

  #  # The following is not needed as the block chain is rolled back, anyway
  #
  #  # Reward beneficiary
  #  vmState.mutateStateDB:
  #   if vmState.generateWitness:
  #     db.collectWitnessData()
  #   db.persist(ClearCache in vmState.flags)

  xp.chain.txRoot = tr.rootHash
  xp.chain.receipts = vmState.receipts

  # calculate reward
  let afterBalance = vmState.readOnlyStateDB.getBalance(xp.chain.miner)
  xp.chain.reward = (afterBalance - minerBalance).truncate(int64).GasPriceEx

  # Block chain will roll back automatically

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
