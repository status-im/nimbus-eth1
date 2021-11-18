# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Tasklets: Update by Bucket
## ===========================================
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
    txs: seq[TxItemRef] ## Squeezer result, return value
    xp: TxPoolRef       ## Descriptor
    tr: HexaryTrie      ## Local state database
    nItems: int         ## Current number of items (for state root calculator)

const
  minEthAddress = block:
    var rc: EthAddress
    rc

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

proc runTx(ctx: var TxSqueezeCtx; item: TxItemRef): GasInt
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Execute item transaction and update `vmState` book keeping. Returns the
  ## `gasUsed` after executing the transaction.
  let
    xp = ctx.xp
    gasTip = item.tx.effectiveGasTip(xp.chain.head.baseFee)

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


proc runTxFinish(ctx: var TxSqueezeCtx; item: TxItemRef; gasBurned: GasInt)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Bool-keeping after executing argument `item` transaction.
  let
    xp = ctx.xp
    vmState = xp.chain.vmState

  # Update sequence sizes so it can be indexed
  if vmState.receipts.len <= ctx.nItems:
    vmState.receipts.setLen(ctx.nItems + receiptsExtensionSize)
    ctx.txs.setLen(ctx.nItems + receiptsExtensionSize)

  ctx.txs[ctx.nItems] = item
  vmState.receipts[ctx.nItems] = vmState.makeReceipt(item.tx.txType)

  #echo "*** runTxFinish ", ctx.nItems,
  #  " gas=", vmState.cumulativeGasUsed,
  #  " -> ", vmState.cumulativeGasUsed + gasBurned,
  #  " ", item.pp

  # Update totals
  vmState.cumulativeGasUsed += gasBurned

  # Incrementally build new state root
  ctx.tr.put(rlp.encode(ctx.nItems), rlp.encode(item.tx))
  ctx.nItems.inc

# --------

proc stepSqueezer(ctx: var TxSqueezeCtx;
                  nonceList: TxStatusNonceRef; fromNonce = AccountNonce.low)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Try to compact items from the `nonceList` argument if there are any. These
  ## items are executed and compacted against `gasBurned` in a loop as long as
  ## the `spaceAvail()` constraint is not violated.
  ##
  ## For each loop step, the block chain can be rolled back. The loop stops
  ## and the last block chain action is rolled back if there is a violation
  ## of the packing constraints.
  let xp = ctx.xp

  var rc = nonceList.ge(fromNonce)
  while rc.isOK:
    let dbTx = xp.chain.db.db.beginTransaction
    defer: dbTx.dispose

    let
      item = rc.value.data
      gasBurned = ctx.runTx(item)

    if gasBurned == 0:
      # Failure: Move this one and higher nonces to pending pucket
      xp.bucketItemsReassignPending(item.status, item.sender, item.tx.nonce)
      # Automatic `tr` database roll back is implied by defer directive
      return

    if not xp.spaceAvail(gasBurned):
      # Automatic `tr` database roll back is implied by defer directive
      return

    ctx.runTxFinish(item, gasBurned)
    dbTx.commit

    rc = nonceList.gt(item.tx.nonce)


proc groupSqueezer(ctx: var TxSqueezeCtx; nonceList: TxStatusNonceRef;
                   fromNonce = AccountNonce.low): AccountNonce
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Try to compact items from the `nonceList` argument if there are any. These
  ## items are compacted against `gasLimit` and then executed in a loop as long
  ## as the `spaceAvail()` constraint is not violated.
  ##
  ## The function returns the next nonce that might be processed. This is
  ## `nonce+1` if `nonce` was the last nonce processed, ot `zero` otherwise.
  let
    xp = ctx.xp
    nItems = ctx.nItems

  var rc = nonceList.ge(fromNonce)
  if rc.isOK:
    let dbTx = xp.chain.db.db.beginTransaction
    defer: dbTx.dispose

    while rc.isOK:
      let item = rc.value.data
      if not xp.spaceAvail(item.tx.gasLimit):
        # Will accept the current group of items, except the current one
        break

      let gasBurned = ctx.runTx(item)
      if gasBurned == 0:
        # Failure: Move this one and higher nonces to pending pucket
        xp.bucketItemsReassignPending(item.status, item.sender, item.tx.nonce)
        # Will accept the current group of items, except the current one
        break

      ctx.runTxFinish(item, gasBurned)
      rc = nonceList.gt(item.tx.nonce)

    # Accept group of compacred items
    dbTx.commit

    # Result
    if nItems < ctx.nItems:
      result = ctx.txs[ctx.nItems - 1].tx.nonce + 1

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc squeezeVmExec*(xp:  TxPoolRef): seq[TxItemRef]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Execute all txs in the `packed` bucket and return the list of collected
  ## items.
  let
    vmState = xp.chain.vmState(pristine = true)
    nextBlockNum = xp.chain.head.blockNumber + 1
    rcPacked = xp.txDB.byStatus.eq(txItemPacked)
    rcStaged = xp.txDB.byStatus.eq(txItemStaged)

  let dbTx = xp.chain.db.db.beginTransaction
  defer: dbTx.dispose()

  if xp.chain.config.daoForkSupport and
     xp.chain.config.daoForkBlock == nextBlockNum:
    vmState.mutateStateDB:
      db.applyDAOHardFork()

  # Internal descriptor
  var ctx = TxSqueezeCtx(
    txs: @[],
    xp: xp,
    tr: newMemoryDB().initHexaryTrie,
    nItems: 0)

  # Try to compact items from the `packed` bucket as long as the
  # `spaceAvail()` constraint is not violated.
  if rcPacked.isOK:
    var rc = rcPacked.ge(minEthAddress)
    while rc.isOK and xp.spaceAvail(0):
      let (account, nonceList) = (rc.value.key, rc.value.data)
      # Try/execute all from the `packed` while accumulated `gasLimits` fit
      # the packing constraints.
      var nonce = ctx.groupSqueezer(nonceList)
      # Compact in additional items from the `packed` bucket if incidentally
      # there are more. This packer executes the item in the VM and then
      # uses the `gasUsed` result for compacting.
      ctx.stepSqueezer(nonceList, nonce)
      # Fetch next list item
      rc = rcPacked.gt(account)

  # Improve packing by processing the `stages` bucket.
  if rcStaged.isOK:
    var bothBuckets: seq[TxStatusNonceRef]
    if xp.continueSqueezing:
      # Try to compact items from yet untouched accounts from `staged` bucket.
      # These are the ones with accounts not in the `packed` bucket.
      #
      # FIXME: Omitting the accounts that share both buckets `staged` and
      #        `packed` at least increases the number of accounts in the
      #        packed block. Whether this leads to better packing results
      #        is unclear.
      var rc = rcStaged.ge(minEthAddress)
      while rc.isOK and xp.continueSqueezing:
        let (account, nonceList) = (rc.value.key, rc.value.data)
        # Not trying this one if the account is in the `packed` bucket'.
        if rcPacked.eq(account).isOk:
          bothBuckets.add nonceList
        else:
          ctx.stepSqueezer(nonceList)
        # Fetch next list item
        rc = rcStaged.gt(account)

    if xp.continueSqueezing:
      # Improve packing by re-vising accounts from the `packed` bucket which
      # are also in the `staged` bucket.
      for nonceList in bothBuckets:
        ctx.stepSqueezer(nonceList)

  xp.chain.nextTxRoot = ctx.tr.rootHash

  # Update flexi-arrays, set proper length
  ctx.txs.setLen(ctx.nItems)
  vmState.receipts.setLen(ctx.nItems)

  #  # The following is not needed as the blcok chain is rolled back anyway
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

  # Block chain will roll back automatically
  ctx.txs

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
