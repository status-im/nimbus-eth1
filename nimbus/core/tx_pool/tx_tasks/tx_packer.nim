# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
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

{.push raises: [].}

import
  chronicles,
  eth/[keys, rlp],
  stew/sorted_set,
  ../../../db/[ledger, core_db],
  ../../../common/common,
  ../../../utils/utils,
  ../../../constants,
  "../.."/[dao, executor, validate, eip4844, casper],
  ../../../transaction/call_evm,
  ../../../transaction,
  ../../../vm_state,
  ../../../vm_types,
  ".."/[tx_chain, tx_desc, tx_item, tx_tabs, tx_tabs/tx_status, tx_info],
  "."/[tx_bucket, tx_classify]

type
  TxPackerError* = object of CatchableError
    ## Catch and relay exception error

  TxPackerStateRef = ref object
    xp: TxPoolRef
    tr: CoreDxMptRef
    cleanState: bool
    balance: UInt256
    blobGasUsed: uint64
    numBlobPerBlock: int

const
  receiptsExtensionSize = ##\
    ## Number of slots to extend the `receipts[]` at the same time.
    20

logScope:
  topics = "tx-pool packer"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

when false:
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

proc persist(pst: TxPackerStateRef)
    {.gcsafe,raises: [].} =
  ## Smart wrapper
  if not pst.cleanState:
    let fork = pst.xp.chain.nextFork
    pst.xp.chain.vmState.stateDB.persist(clearEmptyAccount = fork >= FkSpurious)
    pst.cleanState = true

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc runTx(pst: TxPackerStateRef; item: TxItemRef): GasInt =
  ## Execute item transaction and update `vmState` book keeping. Returns the
  ## `gasUsed` after executing the transaction.
  let
    fork = pst.xp.chain.nextFork
    baseFee = pst.xp.chain.baseFee
    tx = item.tx.eip1559TxNormalization(baseFee.GasInt)

  let gasUsed = tx.txCallEvm(item.sender, pst.xp.chain.vmState, fork)
  pst.cleanState = false
  doAssert 0 <= gasUsed
  gasUsed

proc runTxCommit(pst: TxPackerStateRef; item: TxItemRef; gasBurned: GasInt)
    {.gcsafe,raises: [CatchableError].} =
  ## Book keeping after executing argument `item` transaction in the VM. The
  ## function returns the next number of items `nItems+1`.
  let
    xp = pst.xp
    vmState = xp.chain.vmState
    inx = xp.txDB.byStatus.eq(txItemPacked).nItems
    gasTip = item.tx.effectiveGasTip(xp.chain.baseFee)

  # The gas tip cannot get negative as all items in the `staged` bucket
  # are vetted for profitability before entering that bucket.
  assert 0 <= gasTip
  let reward = gasBurned.u256 * gasTip.uint64.u256
  vmState.stateDB.addBalance(xp.chain.feeRecipient, reward)
  xp.blockValue += reward

  if vmState.collectWitnessData:
    vmState.stateDB.collectWitnessData()

  # Save accounts via persist() is not needed unless the fork is smaller
  # than `FkByzantium` in which case, the `rootHash()` function is called
  # by `makeReceipt()`. As the `rootHash()` function asserts unconditionally
  # that the account cache has been saved, the `persist()` call is
  # obligatory here.
  if xp.chain.nextFork < FkByzantium:
    pst.persist()

  # Update receipts sequence
  if vmState.receipts.len <= inx:
    vmState.receipts.setLen(inx + receiptsExtensionSize)

  # Return remaining gas to the block gas counter so it is
  # available for the next transaction.
  vmState.gasPool += item.tx.gasLimit - gasBurned

  # gasUsed accounting
  vmState.cumulativeGasUsed += gasBurned
  vmState.receipts[inx] = vmState.makeReceipt(item.tx.txType)

  # EIP-4844, count blobGasUsed
  if item.tx.txType >= TxEip4844:
    pst.blobGasUsed += item.tx.getTotalBlobGas

  # Update txRoot
  pst.tr.merge(rlp.encode(inx), rlp.encode(item.tx)).isOkOr:
    raiseAssert "runTxCommit(): merge failed, " & $$error

  # Add the item to the `packed` bucket. This implicitely increases the
  # receipts index `inx` at the next visit of this function.
  discard xp.txDB.reassign(item,txItemPacked)

# ------------------------------------------------------------------------------
# Private functions: packer packerVmExec() helpers
# ------------------------------------------------------------------------------

proc vmExecInit(xp: TxPoolRef): Result[TxPackerStateRef, string]
    {.gcsafe,raises: [CatchableError].} =

  # Flush `packed` bucket
  xp.bucketFlushPacked

  # reset blockValue before adding any tx
  xp.blockValue = 0.u256

  xp.chain.maxMode = (packItemsMaxGasLimit in xp.pFlags)

  if xp.chain.com.daoForkSupport and
     xp.chain.com.daoForkBlock.get == xp.chain.head.blockNumber + 1:
    xp.chain.vmState.mutateStateDB:
      db.applyDAOHardFork()

  # EIP-4788
  if xp.chain.nextFork >= FkCancun:
    let beaconRoot = xp.chain.com.pos.parentBeaconBlockRoot
    xp.chain.vmState.processBeaconBlockRoot(beaconRoot).isOkOr:
      return err(error)

  let packer = TxPackerStateRef( # return value
    xp: xp,
    tr: AristoDbMemory.newCoreDbRef().ctx.getMpt CtGeneric,
    balance: xp.chain.vmState.readOnlyStateDB.getBalance(xp.chain.feeRecipient),
    numBlobPerBlock: 0,
  )
  ok(packer)

proc vmExecGrabItem(pst: TxPackerStateRef; item: TxItemRef): Result[bool,void]
    {.gcsafe,raises: [CatchableError].}  =
  ## Greedily collect & compact items as long as the accumulated `gasLimit`
  ## values are below the maximum block size.
  let
    xp = pst.xp
    vmState = xp.chain.vmState

  if not item.tx.validateChainId(xp.chain.com.chainId):
    discard xp.txDB.dispose(item, txInfoChainIdMismatch)
    return ok(false) # continue with next account

  # EIP-4844
  if pst.numBlobPerBlock + item.tx.versionedHashes.len > MAX_BLOBS_PER_BLOCK:
    return ok(false) # continue with next account
  pst.numBlobPerBlock += item.tx.versionedHashes.len

  # Verify we have enough gas in gasPool
  if vmState.gasPool < item.tx.gasLimit:
    # skip this transaction and
    # continue with next account
    # if we don't have enough gas
    return ok(false)
  vmState.gasPool -= item.tx.gasLimit

  # Validate transaction relative to the current vmState
  if not xp.classifyValidatePacked(vmState, item):
    return ok(false) # continue with next account

  # EIP-1153
  vmState.stateDB.clearTransientStorage()

  let
    accTx = vmState.stateDB.beginSavepoint
    gasUsed = pst.runTx(item) # this is the crucial part, running the tx

  # Find out what to do next: accepting this tx or trying the next account
  if not xp.classifyPacked(vmState.cumulativeGasUsed, gasUsed):
    vmState.stateDB.rollback(accTx)
    if xp.classifyPackedNext(vmState.cumulativeGasUsed, gasUsed):
      return ok(false) # continue with next account
    return err()       # otherwise stop collecting

  # Commit account state DB
  vmState.stateDB.commit(accTx)

  vmState.stateDB.persist(clearEmptyAccount = xp.chain.nextFork >= FkSpurious)
  # let midRoot = vmState.stateDB.rootHash -- notused

  # Finish book-keeping and move item to `packed` bucket
  pst.runTxCommit(item, gasUsed)

  ok(true) # fetch the very next item


proc vmExecCommit(pst: TxPackerStateRef)
    {.gcsafe,raises: [].} =
  let
    xp = pst.xp
    vmState = xp.chain.vmState

  # EIP-4895
  if xp.chain.nextFork >= FkShanghai:
    for withdrawal in xp.chain.com.pos.withdrawals:
      vmState.stateDB.addBalance(withdrawal.address, withdrawal.weiAmount)

  # Reward beneficiary
  vmState.mutateStateDB:
    if vmState.collectWitnessData:
      db.collectWitnessData()
    # Finish up, then vmState.stateDB.rootHash may be accessed
    db.persist(clearEmptyAccount = xp.chain.nextFork >= FkSpurious)

  # Update flexi-array, set proper length
  let nItems = xp.txDB.byStatus.eq(txItemPacked).nItems
  vmState.receipts.setLen(nItems)

  xp.chain.receipts = vmState.receipts
  xp.chain.txRoot = pst.tr.getColumn.state.valueOr:
    raiseAssert "vmExecCommit(): state() failed " & $$error
  xp.chain.stateRoot = vmState.stateDB.rootHash

  if vmState.com.forkGTE(Cancun):
    # EIP-4844
    xp.chain.excessBlobGas = some(vmState.blockCtx.excessBlobGas)
    xp.chain.blobGasUsed = some(pst.blobGasUsed)

  proc balanceDelta: UInt256 =
    let postBalance = vmState.readOnlyStateDB.getBalance(xp.chain.feeRecipient)
    if pst.balance < postBalance:
      return postBalance - pst.balance

  xp.chain.profit = balanceDelta()
  xp.chain.reward = balanceDelta()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc packerVmExec*(xp: TxPoolRef): Result[void, string] {.gcsafe,raises: [CatchableError].} =
  ## Rebuild `packed` bucket by selection items from the `staged` bucket
  ## after executing them in the VM.
  let db = xp.chain.com.db
  let dbTx = db.newTransaction
  defer: dbTx.dispose()

  var pst = xp.vmExecInit.valueOr:
    return err(error)

  block loop:
    for (_,nonceList) in pst.xp.txDB.packingOrderAccounts(txItemStaged):

      block account:
        for item in nonceList.incNonce:
          let rc = pst.vmExecGrabItem(item)
          if rc.isErr:
            break loop    # stop
          if not rc.value:
            break account # continue with next account

  pst.vmExecCommit
  ok()
  # Block chain will roll back automatically

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
