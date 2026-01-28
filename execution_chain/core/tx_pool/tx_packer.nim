# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
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

{.push raises: [], gcsafe.}

import
  stew/sorted_set,
  stew/byteutils,
  ../../db/ledger,
  ../../common/common,
  ../../utils/utils,
  ../../constants,
  ../../transaction/call_evm,
  ../../transaction,
  ../../evm/state,
  ../../evm/types,
  ../executor,
  ../validate,
  ../eip4844,
  ../eip6110,
  ../eip7691,
  ./tx_desc,
  ./tx_item,
  ./tx_tabs

type
  TxPacker = ref object
    # Packer state
    vmState: BaseVMState
    numBlobPerBlock: int

    # Packer results
    blockValue: UInt256
    stateRoot: Hash32
    receiptsRoot: Hash32
    logsBloom: Bloom
    packedTxs: seq[TxItemRef]
    withdrawalReqs: seq[byte]
    consolidationReqs: seq[byte]
    depositReqs: seq[byte]

const
  receiptsExtensionSize = ##\
    ## Number of slots to extend the `receipts[]` at the same time.
    20

  ContinueWithNextAccount = true
  StopCollecting = false

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc classifyValidatePacked(vmState: BaseVMState; item: TxItemRef): bool =
  ## Verify the argument `item` against the accounts database. This function
  ## is a wrapper around the `verifyTransaction()` call to be used in a similar
  ## fashion as in `asyncProcessTransactionImpl()`.
  let
    roDB = vmState.readOnlyLedger
    baseFee = vmState.blockCtx.baseFeePerGas.get(0.u256)
    fork = vmState.fork
    gasLimit = vmState.blockCtx.gasLimit
    excessBlobGas = calcExcessBlobGas(vmState.com, vmState.parent, fork)

  roDB.validateTransaction(
    item.tx, item.sender, gasLimit, baseFee, excessBlobGas, vmState.com, fork).isOk

func classifyPacked(vmState: BaseVMState; moreBurned: GasInt): bool =
  ## Classifier for *packing* (i.e. adding up `gasUsed` values after executing
  ## in the VM.) This function checks whether the sum of the arguments
  ## `gasBurned` and `moreGasBurned` is within acceptable constraints.
  let totalGasUsed = vmState.cumulativeGasUsed + moreBurned
  totalGasUsed < vmState.blockCtx.gasLimit

func classifyPackedNext(vmState: BaseVMState): bool =
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

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc runTxCommit(pst: var TxPacker; item: TxItemRef; callResult: LogResult, xp: TxPoolRef) =
  ## Book keeping after executing argument `item` transaction in the VM. The
  ## function returns the next number of items `nItems+1`.
  let
    vmState = pst.vmState
    inx     = pst.packedTxs.len
    gasTip  = item.tx.tip(pst.baseFee)

  let reward = callResult.gasUsed.u256 * gasTip.u256
  if vmState.balTrackerEnabled:
    vmState.balTracker.trackAddBalanceChange(xp.feeRecipient, reward)
  vmState.ledger.addBalance(xp.feeRecipient, reward)
  pst.blockValue += reward

  # Update receipts sequence
  if vmState.receipts.len <= inx:
    vmState.receipts.setLen(inx + receiptsExtensionSize)

  # Return remaining gas to the block gas counter so it is
  # available for the next transaction.
  vmState.gasPool += item.tx.gasLimit - callResult.gasUsed

  # gasUsed accounting
  vmState.cumulativeGasUsed += callResult.gasUsed
  vmState.receipts[inx] = vmState.makeReceipt(item.tx.txType, callResult)
  pst.packedTxs.add item

# ------------------------------------------------------------------------------
# Private functions: packer packerVmExec() helpers
# ------------------------------------------------------------------------------

proc vmExecInit(xp: TxPoolRef): Result[TxPacker, string] =
  let packer = TxPacker(
    vmState: xp.vmState,
    numBlobPerBlock: 0,
    blockValue: 0.u256,
    stateRoot: xp.vmState.parent.stateRoot,
  )

  # Setup block access list tracker for pre‑execution system calls
  if xp.vmState.balTrackerEnabled:
    xp.vmState.balTracker.setBlockAccessIndex(0)
    xp.vmState.balTracker.beginCallFrame()

  # EIP-4788
  if xp.nextFork >= FkCancun:
    let beaconRoot = xp.parentBeaconBlockRoot
    xp.vmState.processBeaconBlockRoot(beaconRoot).isOkOr:
      return err(error)

  # EIP-2935
  if xp.nextFork >= FkPrague:
    xp.vmState.processParentBlockHash(xp.vmState.blockCtx.parentHash).isOkOr:
      return err(error)

  # Commit block access list tracker changes for pre‑execution system calls
  if xp.vmState.balTrackerEnabled:
    xp.vmState.balTracker.commitCallFrame()

  ok(packer)

proc vmExecGrabItem(pst: var TxPacker; item: TxItemRef, xp: TxPoolRef): bool =
  ## Greedily collect & compact items as long as the accumulated `gasLimit`
  ## values are below the maximum block size.
  let
    vmState = pst.vmState

  # EIP-4844
  if item.tx.txType == TxEip4844:
    # EIP-7594
    if vmState.fork >= FkOsaka and item.tx.versionedHashes.len.uint64 > MAX_BLOBS_PER_TX:
      return ContinueWithNextAccount

    let
      maxForkBlobsPerBlock = getMaxBlobsPerBlock(vmState.com, vmState.fork)
      maxBlobsPerBlock =
        if xp.chain.maxBlobs.isSome:
          # https://eips.ethereum.org/EIPS/eip-7872#specification
          # "If the minimum is zero, set the minimum to one."
          min(max(xp.chain.maxBlobs.get, 1).uint64, maxForkBlobsPerBlock)
        else:
          maxForkBlobsPerBlock
    if (pst.numBlobPerBlock + item.tx.versionedHashes.len).uint64 > maxBlobsPerBlock:
      return ContinueWithNextAccount

  let
    blobGasUsed = item.tx.getTotalBlobGas
    maxBlobGasPerBlock = getMaxBlobGasPerBlock(vmState.com, vmState.fork)
  if vmState.blobGasUsed + blobGasUsed > maxBlobGasPerBlock:
    return ContinueWithNextAccount

  # Verify we have enough gas in gasPool
  if vmState.gasPool < item.tx.gasLimit:
    # skip this transaction and
    # continue with next account
    # if we don't have enough gas
    return ContinueWithNextAccount

  # Validate transaction relative to the current vmState
  if not vmState.classifyValidatePacked(item):
    return ContinueWithNextAccount

  if vmState.balTrackerEnabled:
    vmState.balTracker.setBlockAccessIndex(pst.packedTxs.len() + 1)
    vmState.balTracker.beginCallFrame()

  # Execute EVM for this transaction
  let
    accTx = vmState.ledger.beginSavepoint
    callResult = item.tx.txCallEvm(item.sender, pst.vmState, pst.baseFee)

  doAssert 0 <= callResult.gasUsed

  # Find out what to do next: accepting this tx or trying the next account
  if not vmState.classifyPacked(callResult.gasUsed):
    if vmState.balTrackerEnabled:
      vmState.balTracker.rollbackCallFrame(rollbackReads = true)
    vmState.ledger.rollback(accTx)
    if vmState.classifyPackedNext():
      return ContinueWithNextAccount
    return StopCollecting

  # Commit ledger changes
  vmState.ledger.commit(accTx)

  vmState.ledger.persist(clearEmptyAccount = vmState.fork >= FkSpurious)

  # Finish book-keeping
  pst.runTxCommit(item, callResult, xp)

  pst.numBlobPerBlock += item.tx.versionedHashes.len
  vmState.blobGasUsed += blobGasUsed
  vmState.gasPool -= item.tx.gasLimit

  if vmState.balTrackerEnabled:
    vmState.balTracker.commitCallFrame()

  ContinueWithNextAccount

proc vmExecCommit(pst: var TxPacker, xp: TxPoolRef): Result[void, string] =
  let
    vmState = pst.vmState
    ledger = vmState.ledger

  # Setup block access list tracker for post‑execution system calls
  if vmState.balTrackerEnabled:
    vmState.balTracker.setBlockAccessIndex(pst.packedTxs.len() + 1)
    vmState.balTracker.beginCallFrame()

  # EIP-4895
  if vmState.fork >= FkShanghai:
    if vmState.balTrackerEnabled:
      for withdrawal in xp.withdrawals:
        vmState.balTracker.trackAddBalanceChange(withdrawal.address, withdrawal.weiAmount)
        ledger.addBalance(withdrawal.address, withdrawal.weiAmount)
    else:
      for withdrawal in xp.withdrawals:
        ledger.addBalance(withdrawal.address, withdrawal.weiAmount)

  # EIP-6110, EIP-7002, EIP-7251
  if vmState.fork >= FkPrague:
    pst.withdrawalReqs = ?processDequeueWithdrawalRequests(vmState)
    pst.consolidationReqs = ?processDequeueConsolidationRequests(vmState)
    pst.depositReqs = ?parseDepositLogs(vmState.allLogs, vmState.com.depositContractAddress)

  # Finish up, then vmState.ledger.stateRoot may be accessed
  ledger.persist(clearEmptyAccount = vmState.fork >= FkSpurious)

  # Update flexi-array, set proper length
  vmState.receipts.setLen(pst.packedTxs.len)

  pst.receiptsRoot = vmState.receipts.calcReceiptsRoot
  pst.logsBloom = vmState.receipts.createBloom
  pst.stateRoot = vmState.ledger.getStateRoot()

  # Commit block access list tracker changes for post‑execution system calls
  if vmState.balTrackerEnabled:
    vmState.balTracker.commitCallFrame()

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc packerVmExec*(xp: TxPoolRef): Result[TxPacker, string] =
  ## Execute as much transactions as possible.
  var pst = xp.vmExecInit.valueOr:
    return err(error)

  for item in xp.byPriceAndNonce:
    let rc = pst.vmExecGrabItem(item, xp)
    if rc == StopCollecting:
      break

  ?pst.vmExecCommit(xp)
  ok(pst)

func getExtraData(com: CommonRef): seq[byte] =
  if com.extraData.len > 32:
    com.extraData.toBytes[0..<32]
  else:
    com.extraData.toBytes

func assembleHeader*(pst: TxPacker, xp: TxPoolRef): Header =
  ## Generate a new header, a child of the cached `head`
  let
    vmState = pst.vmState
    com = vmState.com

  var header = Header(
    parentHash:    vmState.blockCtx.parentHash,
    ommersHash:    EMPTY_UNCLE_HASH,
    coinbase:      xp.feeRecipient,
    stateRoot:     pst.stateRoot,
    receiptsRoot:  pst.receiptsRoot,
    logsBloom:     pst.logsBloom,
    difficulty:    UInt256.zero(),
    number:        vmState.blockNumber,
    gasLimit:      vmState.blockCtx.gasLimit,
    gasUsed:       vmState.cumulativeGasUsed,
    timestamp:     xp.timestamp,
    extraData:     getExtraData(com),
    mixHash:       xp.prevRandao,
    nonce:         default(Bytes8),
    baseFeePerGas: vmState.blockCtx.baseFeePerGas,
    )

  if com.isShanghaiOrLater(xp.timestamp):
    header.withdrawalsRoot = Opt.some(calcWithdrawalsRoot(xp.withdrawals))

  if com.isCancunOrLater(xp.timestamp):
    header.parentBeaconBlockRoot = Opt.some(xp.parentBeaconBlockRoot)
    header.blobGasUsed = Opt.some vmState.blobGasUsed
    header.excessBlobGas = Opt.some vmState.blockCtx.excessBlobGas

  if com.isPragueOrLater(xp.timestamp):
    let requestsHash = calcRequestsHash([
      (DEPOSIT_REQUEST_TYPE, pst.depositReqs),
      (WITHDRAWAL_REQUEST_TYPE, pst.withdrawalReqs),
      (CONSOLIDATION_REQUEST_TYPE, pst.consolidationReqs)
    ])
    header.requestsHash = Opt.some(requestsHash)

  if com.isAmsterdamOrLater(xp.timestamp):
    let bal = vmState.blockAccessList.expect("block access list exists")
    header.blockAccessListHash = Opt.some(bal[].computeBlockAccessListHash())
    header.slotNumber = Opt.some(xp.slotNumber)

  header


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

iterator packedTxs*(pst: TxPacker): TxItemRef =
  for item in pst.packedTxs:
    yield item

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
