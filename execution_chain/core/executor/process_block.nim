# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [], gcsafe.}

import
  ../../common/common,
  ../../constants,
  ../../utils/utils,
  ../../db/ledger,
  ../../transaction,
  ../../evm/state,
  ../../evm/types,
  ../../block_access_list/block_access_list_validation,
  ../dao,
  ../eip6110,
  ./calculate_reward,
  ./executor_helpers,
  ./process_transaction,
  stew/assign2,
  eth/common/[keys, transaction_utils],
  minilru,
  chronicles,
  results

when compileOption("threads"):
  import std/atomics, taskpools

  type
    PrefetchCtx = object
      cancel: Atomic[bool]
      parent: Header
      blockCtx: BlockContext
      com: CommonRef
      txFrame: CoreDbTxRef

    PrefetchEntry = object
      sig: Signature
      hash: Hash32
      sender: Address
      senderReady: Atomic[bool]
      fv: Flowvar[bool]

  # proc getRefcount(p: pointer): int {.importc: "getRefcount".}

  # template rc(x: ref): int = getRefcount(cast[pointer](x))

  template borrowRef[T](dest, src: ref T) =
    copyMem(addr dest, addr src, sizeof(pointer))

  template unborrowRef[T](dest: ref T) =
    var nilRef: T
    copyMem(addr dest, addr nilRef, sizeof(pointer))

  proc recoverAndPrefetchTask(
      e: ptr PrefetchEntry, tx: ptr Transaction, ctx: ptr PrefetchCtx
  ): bool {.nimcall, gcsafe.} =
    let pk = recover(e[].sig, SkMessage(e[].hash.data))
    e[].sender =
      if pk.isOk(): pk[].to(Address)
      else: default(Address)
    e[].senderReady.store(true, moRelease)

    if ctx == nil:
      return
    if ctx[].cancel.load(moAcquire):
      return
    if e[].sender == default(Address):
      return

    # Create ledger
    let ledger = LedgerRef() 
    ledger.code = typeof(ledger.code).init(0)
    ledger.slots = typeof(ledger.slots).init(0)
    ledger.blockHashes = typeof(ledger.blockHashes).init(0)
    ledger.txFrame.borrowRef(ctx[].txFrame) # to avoid the ref count which is not thread safe
    defer: 
      ledger.txFrame.unborrowRef()
    discard ledger.beginSavePoint()

    # Create EVM
    let vmState = BaseVMState()
    vmState.com.borrowRef(ctx[].com)
    defer: 
      vmState.com.unborrowRef()
    vmState.ledger = ledger
    assign(vmState.parent, ctx[].parent)
    assign(vmState.blockCtx, ctx[].blockCtx)
    const txCtx = default(TxContext)
    assign(vmState.txCtx, txCtx)
    # vmState.flags = flags
    vmState.fork = vmState.determineFork
    # vmState.tracer = nil
    # vmState.receipts.setLen(0)
    # vmState.cumulativeGasUsed = 0
    # vmState.blockRegularGasUsed = 0
    # vmState.blockStateGasUsed = 0
    vmState.gasCosts = vmState.fork.forkToSchedule
    # vmState.blobGasUsed = 0'u64
    # vmState.allLogs.setLen(0)
    # vmState.gasRefunded = 0
    # vmState.balTracker = nil

    # Prefetch transaction
    vmState.prefetchTransaction(tx[], e[].sender)

    true

  template withSenderParallel(
      vmState: BaseVMState, txs: openArray[Transaction], body: untyped,
      taskpool: Taskpool) =
    var ctx = PrefetchCtx(
      parent: vmState.parent,
      blockCtx: vmState.blockCtx,
      com: vmState.com,
      txFrame: vmState.com.db.baseTxFrame()
    )
    ctx.cancel.store(false, moRelease)
    let ctxPtr =
      if vmState.com.optimisticStatePrefetch: addr ctx
      else: nil

    var entries = newSeq[PrefetchEntry](txs.len)

    for i, e in entries.mpairs():
      e.sig = txs[i].signature().valueOr(default(Signature))
      e.hash = txs[i].rlpHashForSigning(txs[i].isEip155)
      e.senderReady.store(false, moRelease)
      let entryPtr = addr e
      let txPtr = unsafeAddr txs[i]
      e.fv = taskpool.spawn recoverAndPrefetchTask(entryPtr, txPtr, ctxPtr)

    try:
      for txIndex {.inject.}, e in entries.mpairs():
        template tx(): untyped =
          txs[txIndex]

        while not e.senderReady.load(moAcquire):
          cpuRelax()
        let sender {.inject.} = e.sender

        body
    finally:
      ctx.cancel.store(true, moRelease)
      for e in entries.mitems():
        discard sync(e.fv)

template withSenderSerial(txs: openArray[Transaction], body: untyped) =
  for txIndex {.inject.}, tx {.inject.} in txs:
    let sender {.inject.} = tx.recoverSender().valueOr(default(Address))
    body

template withSender(vmState: BaseVMState, txs: openArray[Transaction], body: untyped) =
  when compileOption("threads"):
    # Execute transactions offloading the signature checking to the task pool if
    # it's available
    if vmState.com.taskpool == nil:
      withSenderSerial(txs, body)
    else:
      withSenderParallel(vmState, txs, body, vmState.com.taskpool)
  else:
    withSenderSerial(txs, body)

# Factored this out of procBlkPreamble so that it can be used directly for
# stateless execution of specific transactions.
proc processTransactions*(
    vmState: BaseVMState,
    header: Header,
    transactions: seq[Transaction],
    skipReceipts = false,
    collectLogs = false
): Result[void, string] =
  vmState.receipts.setLen(if skipReceipts: 0 else: transactions.len)
  vmState.cumulativeGasUsed = 0
  vmState.blockRegularGasUsed = 0
  vmState.blockStateGasUsed = 0
  vmState.allLogs = @[]

  vmState.withSender(transactions):
    if sender == default(Address):
      return err("Could not get sender for tx with index " & $(txIndex))

    if vmState.balTrackerEnabled:
      vmState.balTracker.setBlockAccessIndex(txIndex + 1)

    let rc = vmState.processTransaction(tx, sender)
    if rc.isErr:
      return err("Error processing tx with index " & $(txIndex) & ":" & rc.error)
    if skipReceipts:
      # TODO don't generate logs at all if we're not going to put them in
      #      receipts
      if collectLogs:
        vmState.allLogs.add rc.value.logEntries
    else:
      vmState.receipts[txIndex] = vmState.makeReceipt(tx.txType, rc.value)
      if collectLogs:
        vmState.allLogs.add vmState.receipts[txIndex].logs
  ok()

proc procBlkPreamble(
    vmState: BaseVMState,
    blk: Block,
    skipValidation, skipReceipts, skipUncles: bool
): Result[void, string] =
  template header(): Header =
    blk.header

  # Setup block access list tracker for pre‑execution system calls
  if vmState.balTrackerEnabled:
    vmState.balTracker.setBlockAccessIndex(0)
    vmState.balTracker.beginCallFrame()

  let com = vmState.com
  if com.daoForkSupport and com.daoForkBlock.get == header.number:
    vmState.mutateLedger:
      ledger.applyDAOHardFork()

  if not skipValidation: # Expensive!
    if blk.transactions.calcTxRoot != header.txRoot:
      return err("Mismatched txRoot")

  if com.isOsakaOrLater(header.timestamp):
    if rlp.getEncodedLength(blk) > MAX_RLP_BLOCK_SIZE:
      return err("Post-Osaka block exceeded MAX_RLP_BLOCK_SIZE")

  if com.isPragueOrLater(header.timestamp):
    if header.requestsHash.isNone:
      return err("Post-Prague block header must have requestsHash")

    vmState.processParentBlockHash(header.parentHash)
  else:
    if header.requestsHash.isSome:
      return err("Pre-Prague block header must not have requestsHash")

  if com.isCancunOrLater(header.timestamp):
    if header.parentBeaconBlockRoot.isNone:
      return err("Post-Cancun block header must have parentBeaconBlockRoot")

    vmState.processBeaconBlockRoot(header.parentBeaconBlockRoot.value)
  else:
    if header.parentBeaconBlockRoot.isSome:
      return err("Pre-Cancun block header must not have parentBeaconBlockRoot")

  if com.isAmsterdamOrLater(header.timestamp):
    if header.blockAccessListHash.isNone:
      return err("Post-Amsterdam block header must have blockAccessListHash")
  else:
    if header.blockAccessListHash.isSome:
      return err("Pre-Amsterdam block header must not have blockAccessListHash")

  # Commit block access list tracker changes for pre‑execution system calls
  if vmState.balTrackerEnabled:
    vmState.balTracker.commitCallFrame()

  if header.txRoot != EMPTY_ROOT_HASH:
    if blk.transactions.len == 0:
      return err("Transactions missing from body")

    let collectLogs = header.requestsHash.isSome and not skipValidation
    ?processTransactions(
      vmState, header, blk.transactions, skipReceipts, collectLogs
    )
  elif blk.transactions.len > 0:
    return err("Transactions in block with empty txRoot")

  # Setup block access list tracker for post‑execution system calls
  if vmState.balTrackerEnabled:
    vmState.balTracker.setBlockAccessIndex(blk.transactions.len() + 1)
    vmState.balTracker.beginCallFrame()

  if com.isShanghaiOrLater(header.timestamp):
    if header.withdrawalsRoot.isNone:
      return err("Post-Shanghai block header must have withdrawalsRoot")
    if blk.withdrawals.isNone:
      return err("Post-Shanghai block body must have withdrawals")

    if vmState.balTrackerEnabled:
      for withdrawal in blk.withdrawals.get:
        vmState.balTracker.trackAddBalanceChange(withdrawal.address, withdrawal.weiAmount)
        vmState.ledger.addBalance(withdrawal.address, withdrawal.weiAmount)
    else:
      for withdrawal in blk.withdrawals.get:
        vmState.ledger.addBalance(withdrawal.address, withdrawal.weiAmount)
  else:
    if header.withdrawalsRoot.isSome:
      return err("Pre-Shanghai block header must not have withdrawalsRoot")
    if blk.withdrawals.isSome:
      return err("Pre-Shanghai block body must not have withdrawals")

  if com.isAmsterdamOrLater(header.timestamp):
    let blockGasUsed = max(vmState.blockRegularGasUsed, vmState.blockStateGasUsed)
    if blockGasUsed != header.gasUsed:
      # TODO replace logging with better error
      debug "gasUsed neq blockGasUsed",
        gasUsed = header.gasUsed, blockGasUsed = blockGasUsed
      return err("gasUsed mismatch")
  else:
    if vmState.cumulativeGasUsed != header.gasUsed:
      # TODO replace logging with better error
      debug "gasUsed neq cumulativeGasUsed",
        gasUsed = header.gasUsed, cumulativeGasUsed = vmState.cumulativeGasUsed
      return err("gasUsed mismatch")

  if header.ommersHash != EMPTY_UNCLE_HASH:
    # TODO It's strange that we persist uncles before processing block but the
    #      rest after...
    if not skipUncles:
      let h = vmState.ledger.txFrame.persistUncles(blk.uncles)
      if h != header.ommersHash:
        return err("ommersHash mismatch")
    elif not skipValidation and computeRlpHash(blk.uncles) != header.ommersHash:
      return err("ommersHash mismatch")
  elif blk.uncles.len > 0:
    return err("Uncles in block with empty uncle hash")

  ok()

proc procBlkEpilogue(
    vmState: BaseVMState,
    blk: Block,
    skipValidation: bool,
    skipReceipts: bool,
    skipStateRootCheck: bool,
    skipPostExecBalCheck: bool
): Result[void, string] =
  template header(): Header =
    blk.header

  # Reward beneficiary
  vmState.mutateLedger:
    # Clearing the account cache here helps manage its size when replaying
    # large ranges of blocks, implicitly limiting its size using the gas limit
    ledger.persist(
      clearEmptyAccount = vmState.com.isSpuriousOrLater(header.number, header.timestamp),
      clearCache = true
    )

  var
    withdrawalReqs: seq[byte]
    consolidationReqs: seq[byte]

  if header.requestsHash.isSome:
    # Execute EIP-7002 and EIP-7251 before calculating stateRoot
    # because they will alter the state
    withdrawalReqs = ?processDequeueWithdrawalRequests(vmState)
    consolidationReqs = ?processDequeueConsolidationRequests(vmState)

  if not skipValidation:
    if not skipPostExecBalCheck and vmState.com.isAmsterdamOrLater(header.timestamp):
      doAssert vmState.balTrackerEnabled
      # Commit block access list tracker changes for post‑execution system calls
      vmState.balTracker.commitCallFrame()

      let
        bal = vmState.balTracker.getBlockAccessList().get()
        balHash = bal[].computeBlockAccessListHash()
      if header.blockAccessListHash.get != balHash:
        debug "wrong blockAccessListHash, generated block access list does not " &
          "match expected blockAccessListHash in header",
          blockNumber = header.number,
          blockHash = header.computeBlockHash,
          parentHash = header.parentHash,
          expected = header.blockAccessListHash.get,
          actual = balHash,
          blockAccessList = $(bal[])
        return err("blockAccessListHash mismatch, expect: " &
          $header.blockAccessListHash.get & ", got: " & $balHash)

    if not skipStateRootCheck:
      let stateRoot = vmState.ledger.getStateRoot()
      if header.stateRoot != stateRoot:
        # TODO replace logging with better error
        debug "wrong stateRoot in block",
          blockNumber = header.number,
          blockHash = header.computeBlockHash,
          parentHash = header.parentHash,
          expected = header.stateRoot,
          actual = stateRoot,
          parentStateRoot = vmState.parent.stateRoot
        return
          err("stateRoot mismatch, expect: " & $header.stateRoot & ", got: " & $stateRoot)

    if not skipReceipts:
      let bloom = createBloom(vmState.receipts)

      if header.logsBloom != bloom:
        debug "wrong logsBloom in block",
          blockNumber = header.number, actual = bloom, expected = header.logsBloom
        return err("bloom mismatch")

      let receiptsRoot = calcReceiptsRoot(vmState.receipts)
      if header.receiptsRoot != receiptsRoot:
        # TODO replace logging with better error
        debug "wrong receiptRoot in block",
          blockNumber = header.number,
          parentHash = header.parentHash.short,
          blockHash = header.computeBlockHash.short,
          actual = receiptsRoot,
          expected = header.receiptsRoot
        return err("receiptRoot mismatch")

    if header.requestsHash.isSome:
      let
        depositReqs =
          ?parseDepositLogs(vmState.allLogs, vmState.com.depositContractAddress)
        requestsHash = calcRequestsHash(
          [
            (DEPOSIT_REQUEST_TYPE, depositReqs),
            (WITHDRAWAL_REQUEST_TYPE, withdrawalReqs),
            (CONSOLIDATION_REQUEST_TYPE, consolidationReqs),
          ]
        )

      if header.requestsHash.get != requestsHash:
        debug "wrong requestsHash in block",
          blockNumber = header.number,
          parentHash = header.parentHash.short,
          blockHash = header.computeBlockHash.short,
          actual = requestsHash,
          expected = header.requestsHash.get
        return err("requestsHash mismatch")

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc processBlock*(
    vmState: BaseVMState, ## Parent environment of header/body block
    blk: Block, ## Header/body block to add to the blockchain
    skipValidation = false,
    skipReceipts = false,
    skipUncles = false,
    skipStateRootCheck = false,
    skipPostExecBalCheck = false,
): Result[void, string] =
  ## Generalised function to processes `blk` for any network.
  ?vmState.procBlkPreamble(blk, skipValidation, skipReceipts, skipUncles)

  # EIP-3675: no reward for miner in POA/POS
  if not vmState.com.proofOfStake(blk.header, vmState.ledger.txFrame):
    vmState.calculateReward(blk.header, blk.uncles)

  ?vmState.procBlkEpilogue(blk, skipValidation, skipReceipts, skipStateRootCheck, skipPostExecBalCheck)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
