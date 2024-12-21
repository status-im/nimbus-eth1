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
  stew/sorted_set,
  stew/byteutils,
  ../../db/ledger,
  ../../common/common,
  ../../utils/utils,
  ../../constants,
  ".."/[executor, validate, casper],
  ../../transaction/call_evm,
  ../../transaction,
  ../../evm/state,
  ../../evm/types,
  ../eip4844,
  ../eip6110,
  ../eip7691,
  "."/[tx_desc, tx_item, tx_tabs, tx_tabs/tx_status, tx_info],
  tx_tasks/[tx_bucket]

type
  TxPacker = object
    # Packer state
    vmState: BaseVMState
    txDB: TxTabsRef
    cleanState: bool
    numBlobPerBlock: int

    # Packer results
    blockValue: UInt256
    stateRoot: Hash32
    receiptsRoot: Hash32
    logsBloom: Bloom
    withdrawalReqs: seq[byte]
    consolidationReqs: seq[byte]
    depositReqs: seq[byte]

  GrabResult = enum
    FetchNextItem
    ContinueWithNextAccount
    StopCollecting

const
  receiptsExtensionSize = ##\
    ## Number of slots to extend the `receipts[]` at the same time.
    20

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc persist(pst: var TxPacker)
    {.gcsafe,raises: [].} =
  ## Smart wrapper
  let vmState = pst.vmState
  if not pst.cleanState:
    let clearEmptyAccount = vmState.fork >= FkSpurious
    vmState.ledger.persist(clearEmptyAccount)
    pst.cleanState = true

proc classifyValidatePacked(vmState: BaseVMState; item: TxItemRef): bool =
  ## Verify the argument `item` against the accounts database. This function
  ## is a wrapper around the `verifyTransaction()` call to be used in a similar
  ## fashion as in `asyncProcessTransactionImpl()`.
  let
    roDB = vmState.readOnlyLedger
    baseFee = vmState.blockCtx.baseFeePerGas.get(0.u256)
    fork = vmState.fork
    gasLimit = vmState.blockCtx.gasLimit
    tx = item.tx.eip1559TxNormalization(baseFee.truncate(GasInt))
    excessBlobGas = calcExcessBlobGas(vmState.parent, vmState.fork >= FkPrague)

  roDB.validateTransaction(
    tx, item.sender, gasLimit, baseFee, excessBlobGas, fork).isOk

proc classifyPacked(vmState: BaseVMState; moreBurned: GasInt): bool =
  ## Classifier for *packing* (i.e. adding up `gasUsed` values after executing
  ## in the VM.) This function checks whether the sum of the arguments
  ## `gasBurned` and `moreGasBurned` is within acceptable constraints.
  let totalGasUsed = vmState.cumulativeGasUsed + moreBurned
  totalGasUsed < vmState.blockCtx.gasLimit

proc classifyPackedNext(vmState: BaseVMState): bool =
  ## Classifier for *packing* (i.e. adding up `gasUsed` values after executing
  ## in the VM.) This function returns `true` if the packing level is still
  ## low enough to proceed trying to accumulate more items.
  ##
  ## This function is typically called as a follow up after a `false` return of
  ## `classifyPack()`.
  vmState.cumulativeGasUsed < vmState.blockCtx.gasLimit

func baseFee(pst: TxPacker): GasInt =
  ## Getter, baseFee for the next bock header. This value is auto-generated
  ## when a new insertion point is set via `head=`.
  if pst.vmState.blockCtx.baseFeePerGas.isSome:
    pst.vmState.blockCtx.baseFeePerGas.get.truncate(GasInt)
  else:
    0.GasInt

func feeRecipient(pst: TxPacker): Address =
  pst.vmState.com.pos.feeRecipient

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc runTx(pst: var TxPacker; item: TxItemRef): GasInt =
  ## Execute item transaction and update `vmState` book keeping. Returns the
  ## `gasUsed` after executing the transaction.
  let
    baseFee = pst.baseFee

  let gasUsed = item.tx.txCallEvm(item.sender, pst.vmState, baseFee)
  pst.cleanState = false
  doAssert 0 <= gasUsed
  gasUsed

proc runTxCommit(pst: var TxPacker; item: TxItemRef; gasBurned: GasInt)
    {.gcsafe,raises: [CatchableError].} =
  ## Book keeping after executing argument `item` transaction in the VM. The
  ## function returns the next number of items `nItems+1`.
  let
    vmState = pst.vmState
    inx = pst.txDB.byStatus.eq(txItemPacked).nItems
    gasTip = item.tx.effectiveGasTip(pst.baseFee)

  # The gas tip cannot get negative as all items in the `staged` bucket
  # are vetted for profitability before entering that bucket.
  assert 0 <= gasTip
  let reward = gasBurned.u256 * gasTip.u256
  vmState.ledger.addBalance(pst.feeRecipient, reward)
  pst.blockValue += reward

  # Save accounts via persist() is not needed unless the fork is smaller
  # than `FkByzantium` in which case, the `getStateRoot()` function is called
  # by `makeReceipt()`. As the `getStateRoot()` function asserts unconditionally
  # that the account cache has been saved, the `persist()` call is
  # obligatory here.
  if vmState.fork < FkByzantium:
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

  # Add the item to the `packed` bucket. This implicitely increases the
  # receipts index `inx` at the next visit of this function.
  discard pst.txDB.reassign(item,txItemPacked)

# ------------------------------------------------------------------------------
# Private functions: packer packerVmExec() helpers
# ------------------------------------------------------------------------------

proc vmExecInit(xp: TxPoolRef): Result[TxPacker, string]
    {.gcsafe,raises: [CatchableError].} =

  # Flush `packed` bucket
  xp.bucketFlushPacked

  let packer = TxPacker(
    vmState: xp.vmState,
    txDB: xp.txDB,
    numBlobPerBlock: 0,
    blockValue: 0.u256,
    stateRoot: xp.vmState.parent.stateRoot,
  )

  # EIP-4788
  if xp.nextFork >= FkCancun:
    let beaconRoot = xp.vmState.com.pos.parentBeaconBlockRoot
    xp.vmState.processBeaconBlockRoot(beaconRoot).isOkOr:
      return err(error)

  # EIP-2935
  if xp.nextFork >= FkPrague:
    xp.vmState.processParentBlockHash(xp.vmState.blockCtx.parentHash).isOkOr:
      return err(error)

  ok(packer)

proc vmExecGrabItem(pst: var TxPacker; item: TxItemRef): GrabResult
    {.gcsafe,raises: [CatchableError].}  =
  ## Greedily collect & compact items as long as the accumulated `gasLimit`
  ## values are below the maximum block size.
  let vmState = pst.vmState

  if not item.tx.validateChainId(vmState.com.chainId):
    discard pst.txDB.dispose(item, txInfoChainIdMismatch)
    return ContinueWithNextAccount

  # EIP-4844
  let maxBlobsPerBlob = getMaxBlobsPerBlock(vmState.fork >= FkPrague)
  if (pst.numBlobPerBlock + item.tx.versionedHashes.len).uint64 > maxBlobsPerBlob:
    return ContinueWithNextAccount
  pst.numBlobPerBlock += item.tx.versionedHashes.len

  let
    blobGasUsed = item.tx.getTotalBlobGas
    maxBlobGasPerBlock = getMaxBlobGasPerBlock(vmState.fork >= FkPrague)
  if vmState.blobGasUsed + blobGasUsed > maxBlobGasPerBlock:
    return ContinueWithNextAccount
  vmState.blobGasUsed += blobGasUsed

  # Verify we have enough gas in gasPool
  if vmState.gasPool < item.tx.gasLimit:
    # skip this transaction and
    # continue with next account
    # if we don't have enough gas
    return ContinueWithNextAccount
  vmState.gasPool -= item.tx.gasLimit

  # Validate transaction relative to the current vmState
  if not vmState.classifyValidatePacked(item):
    return ContinueWithNextAccount

  # EIP-1153
  vmState.ledger.clearTransientStorage()

  let
    accTx = vmState.ledger.beginSavepoint
    gasUsed = pst.runTx(item) # this is the crucial part, running the tx

  # Find out what to do next: accepting this tx or trying the next account
  if not vmState.classifyPacked(gasUsed):
    vmState.ledger.rollback(accTx)
    if vmState.classifyPackedNext():
      return ContinueWithNextAccount
    return StopCollecting

  # Commit account state DB
  vmState.ledger.commit(accTx)

  vmState.ledger.persist(clearEmptyAccount = vmState.fork >= FkSpurious)

  # Finish book-keeping and move item to `packed` bucket
  pst.runTxCommit(item, gasUsed)

  FetchNextItem

proc vmExecCommit(pst: var TxPacker): Result[void, string] =
  let
    vmState = pst.vmState
    ledger = vmState.ledger

  # EIP-4895
  if vmState.fork >= FkShanghai:
    for withdrawal in vmState.com.pos.withdrawals:
      ledger.addBalance(withdrawal.address, withdrawal.weiAmount)

  # EIP-6110, EIP-7002, EIP-7251
  if vmState.fork >= FkPrague:
    pst.withdrawalReqs = processDequeueWithdrawalRequests(vmState)
    pst.consolidationReqs = processDequeueConsolidationRequests(vmState)
    pst.depositReqs = ?parseDepositLogs(vmState.allLogs, vmState.com.depositContractAddress)

  # Finish up, then vmState.ledger.stateRoot may be accessed
  ledger.persist(clearEmptyAccount = vmState.fork >= FkSpurious)

  # Update flexi-array, set proper length
  let nItems = pst.txDB.byStatus.eq(txItemPacked).nItems
  vmState.receipts.setLen(nItems)

  pst.receiptsRoot = vmState.receipts.calcReceiptsRoot
  pst.logsBloom = vmState.receipts.createBloom
  pst.stateRoot = vmState.ledger.getStateRoot()
  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc packerVmExec*(xp: TxPoolRef): Result[TxPacker, string]
      {.gcsafe,raises: [CatchableError].} =
  ## Rebuild `packed` bucket by selection items from the `staged` bucket
  ## after executing them in the VM.
  let db = xp.vmState.com.db
  let dbTx = db.ctx.txFrameBegin()
  defer: dbTx.dispose()

  var pst = xp.vmExecInit.valueOr:
    return err(error)

  block loop:
    for (_,nonceList) in xp.txDB.packingOrderAccounts(txItemStaged):

      block account:
        for item in nonceList.incNonce:
          let rc = pst.vmExecGrabItem(item)
          if rc == StopCollecting:
            break loop    # stop
          if rc == ContinueWithNextAccount:
            break account # continue with next account

  ?pst.vmExecCommit()
  ok(pst)
  # Block chain will roll back automatically

func getExtraData(com: CommonRef): seq[byte] =
  if com.extraData.len > 32:
    com.extraData.toBytes[0..<32]
  else:
    com.extraData.toBytes

proc assembleHeader*(pst: TxPacker): Header =
  ## Generate a new header, a child of the cached `head`
  let
    vmState = pst.vmState
    com = vmState.com
    pos = com.pos

  result = Header(
    parentHash:    vmState.blockCtx.parentHash,
    ommersHash:    EMPTY_UNCLE_HASH,
    coinbase:      pos.feeRecipient,
    stateRoot:     pst.stateRoot,
    receiptsRoot:  pst.receiptsRoot,
    logsBloom:     pst.logsBloom,
    difficulty:    UInt256.zero(),
    number:        vmState.blockNumber,
    gasLimit:      vmState.blockCtx.gasLimit,
    gasUsed:       vmState.cumulativeGasUsed,
    timestamp:     pos.timestamp,
    extraData:     getExtraData(com),
    mixHash:       pos.prevRandao,
    nonce:         default(Bytes8),
    baseFeePerGas: vmState.blockCtx.baseFeePerGas,
    )

  if com.isShanghaiOrLater(pos.timestamp):
    result.withdrawalsRoot = Opt.some(calcWithdrawalsRoot(pos.withdrawals))

  if com.isCancunOrLater(pos.timestamp):
    result.parentBeaconBlockRoot = Opt.some(pos.parentBeaconBlockRoot)
    result.blobGasUsed = Opt.some vmState.blobGasUsed
    result.excessBlobGas = Opt.some vmState.blockCtx.excessBlobGas

  if com.isPragueOrLater(pos.timestamp):
    let requestsHash = calcRequestsHash([
      (DEPOSIT_REQUEST_TYPE, pst.depositReqs),
      (WITHDRAWAL_REQUEST_TYPE, pst.withdrawalReqs),
      (CONSOLIDATION_REQUEST_TYPE, pst.consolidationReqs)
    ])
    result.requestsHash = Opt.some(requestsHash)

func blockValue*(pst: TxPacker): UInt256 =
  pst.blockValue

func executionRequests*(pst: var TxPacker): seq[seq[byte]] =
  template append(dst, reqType, reqData) =
    if reqData.len > 0:
      reqData.insert(reqType)
      dst.add(move(reqData))

  result.append(DEPOSIT_REQUEST_TYPE, pst.depositReqs)
  result.append(WITHDRAWAL_REQUEST_TYPE, pst.withdrawalReqs)
  result.append(CONSOLIDATION_REQUEST_TYPE, pst.consolidationReqs)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
