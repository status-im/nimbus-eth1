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
  TxSqueezeError* = object of CatchableError
    ## Catch and relay exception error

  TxSqueezeCtx = object
    xp: TxPoolRef       ## Descriptor
    tr: HexaryTrie      ## Local state database
    nItems: int         ## Current number of items (for state root calculator)

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
]#

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

proc spaceAvail(xp: TxPoolRef; gasUsed: GasInt): bool
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Packing/squeezing constraint for squeezer functions: Continue accumulating
  ## items while this function returns `true`.
  xp.classifySqueezer(xp.chain.vmState.cumulativeGasUsed + gasUsed)

proc continueSqueezing(xp: TxPoolRef): bool
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Packing/squeezing constraint for `stagedSqueezer()`: Continue accumulating
  ## items if this function returns `true`.
  xp.classifySqueezerTryNext(xp.chain.vmState.cumulativeGasUsed)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc runTx(xp: TxPoolRef; item: TxItemRef): GasInt
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Execute item transaction and update `vmState` book keeping. Returns the
  ## `gasUsed` after executing the transaction.
  let gasTip = item.tx.effectiveGasTip(xp.chain.head.baseFee)
  if 0.GasPriceEx <= gasTip:
    let
      fork = xp.chain.nextFork
      vmState = xp.chain.vmState
      miner = xp.chain.miner

    # Execute transaction, may return a wildcard `Exception`
    safeExecutor "tx_bucket.runTx":
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
                 tr: var HexaryTrie; item: TxItemRef; gasBurned: GasInt): bool
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Book keeping after executing argument `item` transaction in the VM. The
  ## function returns the next number of items `nItems+1`.
  let
    vmState = xp.chain.vmState
    inx = xp.txDB.byStatus.eq(txItemPacked).nItems

  # Update sequence sizes so it can be indexed
  if vmState.receipts.len <= inx:
    vmState.receipts.setLen(inx + receiptsExtensionSize)
  vmState.receipts[inx] = vmState.makeReceipt(item.tx.txType)

  # Update totals
  vmState.cumulativeGasUsed += gasBurned

  # Incrementally build new state root
  tr.put(rlp.encode(inx), rlp.encode(item.tx))

  # Add the item to the `packed` bucket
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
    vmState = xp.chain.vmState(pristine = true)
    nextBlockNum = xp.chain.head.blockNumber + 1

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

  # Greedily compact a group of items as long as the accumulated `gasLimit`
  # values are below the block size.
  block groupWise:
    let subTx = xp.chain.db.db.beginTransaction
    defer: subTx.dispose
    block newTransaction:

      for (account,nonceList) in xp.txDB.decAccount(txItemStaged):
        block newAccount:

          for item in nonceList.incNonce:
            if not xp.spaceAvail(item.tx.gasLimit):
              # Will accept the current group of items, except the current one
              break newTransaction

            let gasBurned = xp.runTx(item)
            if gasBurned == 0:
              # Failure: Move this account and higher nonces to pending pucket
              xp.bucketItemsReassignPending(item)
              # Roll back the current `packed` bucket
              xp.bucketFlushPacked
              break groupWise

            # Finish book-keeping and move item to `packed` bucket
            discard xp.runTxFinish(tr, item, gasBurned)

    # Accept group of items (for book-keeping)
    subTx.commit

  block stepWise:
    for (account,nonceList) in xp.txDB.decAccount(txItemStaged):
      block newAccount:

        for item in nonceList.incNonce:
          let subTx = xp.chain.db.db.beginTransaction
          defer: subTx.dispose

          let gasBurned = xp.runTx(item)
          if gasBurned == 0:
            # Failure: Move this account and higher nonces to pending pucket
            xp.bucketItemsReassignPending(item)
            # Accept the current group of items, except this last one
            break newAccount # implies rollback

          if not xp.spaceAvail(gasBurned):
            break newAccount # implies rollback

          # Finish book-keeping and move item to `packed` bucket
          discard xp.runTxFinish(tr, item, gasBurned)

          subTx.commit

  #  # The following is not needed as the block chain is rolled back, anyway
  #
  # # Update flexi-arrays, set proper length
  # vmState.receipts.setLen(ctx.nItems)
  #
  #  if not vmState.chainDB.config.poaEngine:
  #   # @[]: no uncles yet
  #   vmState.calculateReward(xp.chain.miner, nextBlockNum, @[])
  #
  #  # Reward beneficiary
  #  vmState.mutateStateDB:
  #   if vmState.generateWitness:
  #     db.collectWitnessData()
  #   db.persist(ClearCache in vmState.flags)

  xp.chain.nextTxRoot = tr.rootHash
  # Block chain will roll back automatically

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
