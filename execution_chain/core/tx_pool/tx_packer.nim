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
  ../../evm/interpreter/gas_costs,
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
    txsRlpSize: uint64
    withdrawalsRlpSize: uint64
    headerFixedSize: uint64

    # Packer results
    blockValue: UInt256
    stateRoot: Hash32
    receiptsRoot: Hash32
    logsBloom: Bloom
    packedTxs: seq[TxItemRef]
    withdrawalReqs: seq[byte]
    consolidationReqs: seq[byte]
    depositReqs: seq[byte]
    builderDepositReqs: seq[byte]
    builderExitReqs: seq[byte]

const
  receiptsExtensionSize = ##\
    ## Number of slots to extend the `receipts[]` at the same time.
    20

  ContinueWithNextAccount = true
  StopCollecting = false

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func getExtraData(com: CommonRef): seq[byte] =
  if com.extraData.len > 32:
    com.extraData.toBytes[0..<32]
  else:
    com.extraData.toBytes

func blockGasUsed(vmState: BaseVMState): GasInt =
  ## Gas counted against the block gas limit so far
  if vmState.fork >= FkAmsterdam:
    # EIP-8037
    max(vmState.blockExecutionGasUsed, vmState.blockStateGasUsed)
  else:
    vmState.cumulativeGasUsed

func minTxGas(fork: EVMFork): GasInt =
  ## Intrinsic gas of the cheapest possible tx, see `intrinsicGas`
  if fork >= FkAmsterdam: TX_BASE_COST_2780
  else: TX_BASE_COST

func rlpLengthBytes(v: uint64): uint64 =
  var v = v
  while v > 0:
    inc result
    v = v shr 8

func rlpListPrefixLen(payloadLen: uint64): uint64 =
  if payloadLen <= 55: 1'u64
  else: 1'u64 + rlpLengthBytes(payloadLen)

func rlpListPayloadLen(encodedLen: uint64): uint64 =
  ## Inverse of `rlpListPrefixLen(p) + p`
  result = encodedLen - 1
  while rlpListPrefixLen(result) + result > encodedLen:
    dec result

func rlpUintLen(v: uint64): uint64 =
  ## Encoded size of `v` as an RLP integer
  if v < 128: 1'u64
  else: 1'u64 + rlpLengthBytes(v)

proc prospectiveHeaderFixedSize(xp: TxPoolRef): uint64 =
  ## RLP payload size of the post-Osaka header, minus `gasUsed` and
  ## `blobGasUsed` — the only fields whose encoded size depends on the packed
  ## txs. Everything else is either known before packing starts or fixed-width
  ## (hash roots, bloom).
  let
    vmState = xp.vmState
    com = vmState.com

  var header = Header(
    number:        vmState.blockNumber,
    gasLimit:      vmState.blockCtx.gasLimit,
    gasUsed:       0,
    timestamp:     xp.timestamp,
    extraData:     getExtraData(com),
    baseFeePerGas: Opt.some(xp.baseFee.u256),
  )
  if com.isShanghaiOrLater(xp.timestamp):
    header.withdrawalsRoot = Opt.some(default(Hash32))
  if com.isCancunOrLater(xp.timestamp):
    header.parentBeaconBlockRoot = Opt.some(default(Hash32))
    header.blobGasUsed = Opt.some(0'u64)
    header.excessBlobGas = Opt.some(vmState.blockCtx.excessBlobGas)
  if com.isPragueOrLater(xp.timestamp):
    header.requestsHash = Opt.some(default(Hash32))
  if com.isAmsterdamOrLater(xp.timestamp):
    header.blockAccessListHash = Opt.some(default(Hash32))
    header.slotNumber = Opt.some(xp.slotNumber)

  rlpListPayloadLen(rlp.getEncodedLength(header).uint64) -
    2 * rlpUintLen(0) # zero `gasUsed` and `blobGasUsed`

func prospectiveBlockSize(pst: TxPacker, item: TxItemRef): uint64 =
  ## Exact encoded size of the assembled block if `item` is packed next.
  ## `gasUsed` is substituted with a value that RLP-encodes to at least as
  ## many bytes as the final one, so the result never underestimates — a
  ## block passing this check cannot exceed the cap.
  let
    vmState = pst.vmState
    gasUsed = min(vmState.blockGasUsed + item.tx.gasLimit, vmState.blockCtx.gasLimit)
    blobGasUsed = vmState.blobGasUsed + item.tx.getTotalBlobGas
    headerLen = pst.headerFixedSize + rlpUintLen(gasUsed) + rlpUintLen(blobGasUsed)
    txsLen = pst.txsRlpSize + item.rlpSize
    bodyLen = rlpListPrefixLen(headerLen) + headerLen +
              rlpListPrefixLen(txsLen) + txsLen +
              1 +   # empty ommers list
              pst.withdrawalsRlpSize
  rlpListPrefixLen(bodyLen) + bodyLen

func classifyPackedNext(vmState: BaseVMState): bool =
  ## Classifier for *packing* (i.e. adding up `gasUsed` values after executing
  ## in the VM.) This function returns `true` if the packing level is still
  ## low enough to proceed trying to accumulate more items.
  ##
  ## This function is typically called as a follow up after a `false` return of
  ## `classifyPack()`.
  vmState.blockGasUsed < vmState.blockCtx.gasLimit

# ------------------------------------------------------------------------------
# Private functions: packer packerVmExec() helpers
# ------------------------------------------------------------------------------

proc vmExecInit(xp: TxPoolRef): Result[TxPacker, string] =
  let
    vmState = xp.vmState
    packer = TxPacker(
      vmState: vmState,
      numBlobPerBlock: 0,
      blockValue: 0.u256,
      stateRoot: vmState.parent.stateRoot,
    )

  # EIP-7934: the withdrawals are part of the encoded block and their exact
  # size is known before packing starts
  if xp.nextFork >= FkShanghai:
    packer.withdrawalsRlpSize = rlp.getEncodedLength(xp.withdrawals).uint64
  if xp.nextFork >= FkOsaka:
    packer.headerFixedSize = xp.prospectiveHeaderFixedSize()

  # Setup block access list tracker for pre‑execution system calls
  if vmState.balTrackerEnabled:
    vmState.balTracker.setBlockAccessIndex(0)
    vmState.balTracker.beginCallFrame()

  # EIP-4788
  if xp.nextFork >= FkCancun:
    let beaconRoot = xp.parentBeaconBlockRoot
    vmState.processBeaconBlockRoot(beaconRoot)

  # EIP-2935
  if xp.nextFork >= FkPrague:
    vmState.processParentBlockHash(vmState.blockCtx.parentHash)

  # Commit block access list tracker changes for pre‑execution system calls
  if vmState.balTrackerEnabled:
    vmState.balTracker.commitCallFrame()

  ok(packer)

proc vmExecGrabItem(pst: var TxPacker; item: TxItemRef): bool =
  ## Greedily collect & compact items as long as the accumulated `gasLimit`
  ## values are below the maximum block size.
  let
    vmState = pst.vmState

  # Nothing fits once less gas than the cheapest possible tx needs is left
  if vmState.blockCtx.gasLimit - vmState.blockGasUsed < vmState.fork.minTxGas:
    return StopCollecting

  # Same check `processTransaction` starts with, minus building its error
  # message. The pool then skips the sender's later txs, as they can't fit
  # without this one.
  template doesNotFit(_: untyped) =
    return ContinueWithNextAccount
  check2dGasInclusion(vmState, item.tx.gasLimit, doesNotFit)

  # EIP-4844
  if item.tx.txType == TxEip4844:
    # EIP-7594
    if vmState.fork >= FkOsaka and item.tx.versionedHashes.len.uint64 > MAX_BLOBS_PER_TX:
      return ContinueWithNextAccount

    let
      maxBlobs = vmState.com.maxBlobs
      maxForkBlobsPerBlock = getMaxBlobsPerBlock(vmState.com, vmState.hardFork)
      maxBlobsPerBlock =
        if maxBlobs.isSome:
          # https://eips.ethereum.org/EIPS/eip-7872#specification
          # "If the minimum is zero, set the minimum to one."
          min(max(maxBlobs.get, 1).uint64, maxForkBlobsPerBlock)
        else:
          maxForkBlobsPerBlock
    if (pst.numBlobPerBlock + item.tx.versionedHashes.len).uint64 > maxBlobsPerBlock:
      return ContinueWithNextAccount

  # EIP-7934: a tx that cannot fit within the block RLP size limit must not
  # be executed at all, otherwise the header gas values, receipts and the
  # EIP-7928 block access list would commit to a tx missing from the body
  if vmState.fork >= FkOsaka and
      pst.prospectiveBlockSize(item) > MAX_RLP_BLOCK_SIZE.uint64:
    return ContinueWithNextAccount

  if vmState.balTrackerEnabled:
    vmState.balTracker.setBlockAccessIndex(pst.packedTxs.len() + 1)

  # Find out what to do next: accepting this tx or trying the next account
  var rc = processTransaction(vmState, item.tx, item.sender, rollbackReads = true)
  if rc.isErr:
    if vmState.classifyPackedNext():
      return ContinueWithNextAccount
    return StopCollecting

  # Finish book-keeping
  let inx = pst.packedTxs.len

  # Update receipts sequence
  if vmState.receipts.len <= inx:
    vmState.receipts.setLen(inx + receiptsExtensionSize)
    vmState.receiptBlooms.setLen(inx + receiptsExtensionSize)

  vmState.blockLogs.addDepositLogs(vmState.txLogs, vmState.com.depositContractAddress)
  vmState.receipts[inx] = vmState.makeReceipt(item.tx.txType)
  vmState.receiptBlooms[inx] = calcLogsBloom(vmState.receipts[inx].logs)

  pst.packedTxs.add item
  pst.numBlobPerBlock += item.tx.versionedHashes.len
  pst.blockValue += rc.value.txFee
  pst.txsRlpSize += item.rlpSize

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
        vmState.balTracker.trackAddressAccess(withdrawal.address)
        ledger.addBalance(withdrawal.address, withdrawal.weiAmount, checkEmptyAccount = false)
    else:
      for withdrawal in xp.withdrawals:
        ledger.addBalance(withdrawal.address, withdrawal.weiAmount, checkEmptyAccount = false)

  # EIP-6110, EIP-7002, EIP-7251
  if vmState.fork >= FkPrague:
    pst.withdrawalReqs = ?processDequeueWithdrawalRequests(vmState)
    pst.consolidationReqs = ?processDequeueConsolidationRequests(vmState)
    pst.depositReqs = ?parseDepositLogs(vmState.blockLogs)

    if vmState.fork >= FkAmsterdam:
      # EIP-8282
      pst.builderDepositReqs = ?processBuilderDepositRequests(vmState)
      pst.builderExitReqs = ?processBuilderExitRequests(vmState)


  # Finish up, then vmState.ledger.stateRoot may be accessed
  ledger.persist(clearEmptyAccount = vmState.fork >= FkSpurious)

  # Update flexi-array, set proper length
  vmState.receipts.setLen(pst.packedTxs.len)
  vmState.receiptBlooms.setLen(pst.packedTxs.len)

  pst.receiptsRoot = calcReceiptsRoot(vmState.receipts, vmState.receiptBlooms)
  createBloom(vmState.receiptBlooms, pst.logsBloom)
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

  if xp.isOrdered:
    for item in xp.byOrder:
      let rc = pst.vmExecGrabItem(item)
      if rc == StopCollecting:
        break
  else:
    for item in xp.byPriceAndNonce:
      let rc = pst.vmExecGrabItem(item)
      if rc == StopCollecting:
        break

  ?pst.vmExecCommit(xp)
  ok(pst)

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
    baseFeePerGas: Opt.some(xp.baseFee.u256),
    )

  if com.isShanghaiOrLater(xp.timestamp):
    header.withdrawalsRoot = Opt.some(calcWithdrawalsRoot(xp.withdrawals))

  if com.isCancunOrLater(xp.timestamp):
    header.parentBeaconBlockRoot = Opt.some(xp.parentBeaconBlockRoot)
    header.blobGasUsed = Opt.some vmState.blobGasUsed
    header.excessBlobGas = Opt.some vmState.blockCtx.excessBlobGas

  if com.isPragueOrLater(xp.timestamp):
    let requestsHash = if com.isAmsterdamOrLater(xp.timestamp):
        calcRequestsHash([
          (DEPOSIT_REQUEST_TYPE, pst.depositReqs),
          (WITHDRAWAL_REQUEST_TYPE, pst.withdrawalReqs),
          (CONSOLIDATION_REQUEST_TYPE, pst.consolidationReqs),
          (BUILDER_DEPOSIT_REQUEST_TYPE, pst.builderDepositReqs),
          (BUILDER_EXIT_REQUEST_TYPE, pst.builderExitReqs),
        ])
      else:
        calcRequestsHash([
          (DEPOSIT_REQUEST_TYPE, pst.depositReqs),
          (WITHDRAWAL_REQUEST_TYPE, pst.withdrawalReqs),
          (CONSOLIDATION_REQUEST_TYPE, pst.consolidationReqs)
        ])
    header.requestsHash = Opt.some(requestsHash)

  if com.isAmsterdamOrLater(xp.timestamp):
    let bal = vmState.blockAccessList.expect("block access list exists")
    header.blockAccessListHash = Opt.some(bal[].computeBlockAccessListHash())
    header.slotNumber = Opt.some(xp.slotNumber)
    header.gasUsed = max(vmState.blockExecutionGasUsed, vmState.blockStateGasUsed)

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

  # EIP-8282: must mirror `assembleHeader`, which folds these into
  # `requestsHash`. Omitting them here yields a payload whose recomputed
  # requestsHash disagrees with the committed header, i.e. a block hash
  # mismatch on every `engine_newPayload` receiver -- including ourselves.
  if pst.vmState.fork >= FkAmsterdam:
    result.append(BUILDER_DEPOSIT_REQUEST_TYPE, pst.builderDepositReqs)
    result.append(BUILDER_EXIT_REQUEST_TYPE, pst.builderExitReqs)

iterator packedTxs*(pst: TxPacker): TxItemRef =
  for item in pst.packedTxs:
    yield item

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
