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
  std/algorithm,
  ../../common/common,
  ../../constants,
  ../../utils/utils,
  ../../db/ledger,
  ../../db/core_db,
  ../../transaction,
  ../../evm/state,
  ../../evm/types,
  ../../evm/precompiles,
  ../../evm/interpreter/gas_costs,
  ../../block_access_list/block_access_list_validation,
  ../../concurrency/utils,
  ../dao,
  ../eip6110,
  ./calculate_reward,
  ./executor_helpers,
  ./process_transaction,
  eth/common/[keys, transaction_utils],
  chronicles,
  results,
  stew/assign2

when compileOption("threads"):
  import std/atomics, taskpools

  type
    Entry = object
      sig: Signature
      hash: Hash32
      sender: Address
      senderReady: Atomic[bool]
      fut: Flowvar[bool]

    PrefetchCtx = object
      cancel: Atomic[bool]
      parent: Header
      blockCtx: BlockContext
      com: CommonRef
      txFrame: CoreDbTxRef

    BalPrefetchCtx = object
      finished: Atomic[bool]
      nextIndex: Atomic[int]
      balPtr: ptr BlockAccessList
      txFrame: CoreDbTxRef
      fork: EVMFork

  proc recoverAndPrefetchTask(
      e: ptr Entry, ctx: ptr PrefetchCtx, tx: ptr Transaction): bool {.nimcall.} =
    # Recover the sender from the signature. `default(Address)` signals sig
    # check failure.
    let
      pk = recover(e[].sig, SkMessage(e[].hash.data))
      sender =
        if pk.isOk(): pk[].to(Address)
        else: default(Address)
    e[].sender = sender
    e[].senderReady.store(true, moRelease)

    # When ctx is non-nil, optimistic state prefetch is enabled
    if ctx.isNil() or sender == default(Address) or ctx[].cancel.load(moAcquire):
      return true

    # Create the ledger without triggering a ref count increment on the txFrame
    # which is owned by the main/parent thread.
    let ledger = LedgerRef()
    ledger.txFrame.borrowRef(ctx[].txFrame)
    defer:
      ledger.txFrame.unborrowRef()
    discard ledger.beginSavePoint()

    # Create the vmState without triggering a ref count increment on the common object
    # which is owned by the main/parent thread.
    let vmState = BaseVMState()
    vmState.com.borrowRef(ctx[].com)
    defer:
      vmState.com.unborrowRef()
    vmState.ledger = ledger
    assign(vmState.parent, ctx[].parent)
    assign(vmState.blockCtx, ctx[].blockCtx)
    const txCtx = default(TxContext)
    assign(vmState.txCtx, txCtx)
    vmState.hardFork = vmState.determineFork
    vmState.fork = ToEVMFork[vmState.hardFork]
    vmState.gasCosts = vmState.fork.forkToSchedule
    vmState.tracer = nil
    vmState.receipts.setLen(0)
    vmState.cumulativeGasUsed = 0
    vmState.blockRegularGasUsed = 0
    vmState.blockStateGasUsed = 0
    vmState.blobGasUsed = 0'u64
    vmState.allLogs.setLen(0)
    vmState.gasRefunded = 0
    vmState.balTracker = nil

    # Execute the transaction discarding the results in order to fill the in memory caches.
    vmState.prefetchTransaction(tx[], sender)

    true

  template withSenderParallel(
      vmState: BaseVMState, txs: openArray[Transaction], body: untyped) =
    # Execute transactions offloading the signature checking to the task pool
    var
      entries = newSeq[Entry](txs.len)
      ctx: PrefetchCtx
      ctxPtr: ptr PrefetchCtx = nil

    if vmState.com.optimisticStatePrefetch and not vmState.balPrefetchActive:
      ctx.parent = vmState.parent
      ctx.blockCtx = vmState.blockCtx
      ctx.com = vmState.com
      # Run the prefetch on the parent frame because the current frame will
      # be writen to during block execution and this way we avoid having to
      # use locking on the frame data structures.
      ctx.txFrame = vmState.ledger.txFrame.parent()
      ctx.cancel.store(false, moRelease)
      ctxPtr = ctx.addr

    # Spawn one task per transaction that recovers the sender and, when ctxPtr
    # is non-nil, also performs an optimistic state prefetch. Spawning here
    # allows the task to start early, while we still haven't hashed subsequent txs.
    for i, e in entries.mpairs():
      e.sig = txs[i].signature().valueOr(default(Signature))
      e.hash = txs[i].rlpHashForSigning(txs[i].isEip155)
      let entryPtr = e.addr
      e.fut = vmState.com.taskpool.spawn recoverAndPrefetchTask(
        entryPtr, ctxPtr, txs[i].addr)

    try:
      for txIndex {.inject.}, e in entries.mpairs():
        template tx(): untyped =
          txs[txIndex]

        # Wait until the worker has published the sender.
        while not e.senderReady.load(moAcquire):
          cpuRelax()
        let sender {.inject.} = e.sender

        body
    finally:
      if not ctxPtr.isNil():
        # Cancel any in-flight prefetch tasks so that they bail out quickly.
        ctxPtr[].cancel.store(true, moRelease)
      # Wait for all tasks to complete before returning so that no task
      # outlives the local data it references.
      for e in entries.mitems():
        discard sync(e.fut)

  func firstBalIndex(sc: SlotChanges): BlockAccessIndex =
    ## Earliest block access index at which the slot was written. 
    ## Block access list validation guarantees `changes` is non-empty.
    assert sc.changes.len > 0
    sc.changes[0].blockAccessIndex

  proc balPrefetchWorker(ctx: ptr BalPrefetchCtx): bool {.nimcall.} =
    let len = ctx[].balPtr[].len
    while true:
      if ctx[].finished.load(moAcquire):
        break

      let i = ctx[].nextIndex.fetchAdd(1, moRelaxed)
      if i >= len:
        break

      let accChanges = addr ctx[].balPtr[][i]

      # Precompile contracts don't exist in the state trie and don't get loaded
      # when called so we don't prefetch them. The BAL can contain precompile addresses 
      # but in most cases the state trie account is not actually fetched. The edge
      # case here is when a precompile contract receives a value transfer which will
      # load the account to update the balance but unfortunately we can't determine
      # if this was the case or not from the information in the BAL so we ignore this.
      if isPrecompile(ctx[].fork, accChanges[].address):
        continue

      let accPath = accChanges[].address.computeAccPath

      if accChanges[].storageChanges.len == 0 and accChanges[].storageReads.len == 0:
        discard ctx[].txFrame.fetchAccount(accPath)
        continue

      # Prefetch the written slots ordered by the earliest block access index at
      # which each was written, so they are warmed in roughly the order the block
      # touches them.
      for slotChanges in sorted(accChanges[].storageChanges,
          proc(a, b: SlotChanges): int = cmp(firstBalIndex(a), firstBalIndex(b))):
        discard ctx[].txFrame.fetchSlot(accPath, computeSlotKey(slotChanges.slot))

      for stoRead in accChanges[].storageReads:
        discard ctx[].txFrame.fetchSlot(accPath, computeSlotKey(stoRead))

    true

  template withBalPrefetchParallel(
      vmState: BaseVMState, bal: Opt[BlockAccessListRef], body: untyped) =
      
    let balRef = bal.get()

    var ctx: BalPrefetchCtx
    ctx.balPtr = balRef[].addr
    # Read through the parent frame because the current frame is written to
    # during block execution; this avoids locking on the frame data structures.
    ctx.txFrame = vmState.ledger.txFrame.parent()
    ctx.fork = vmState.fork
    ctx.nextIndex.store(0, moRelease)
    ctx.finished.store(false, moRelease)

    let 
      ctxPtr = ctx.addr
      n = vmState.com.taskpool.numThreads
      configured = vmState.com.balStatePrefetchWorkers
      numWorkers = if configured <= 0: n else: min(configured, n)
    
    var futs = newSeq[Flowvar[bool]](numWorkers)
    for i in 0 ..< numWorkers:
      futs[i] = vmState.com.taskpool.spawn balPrefetchWorker(ctxPtr)

    try:
      body
    finally:
      # Signal completion so workers stop claiming new items, then collect all
      # so that no worker outlives the data it references.
      ctxPtr[].finished.store(true, moRelease)
      for f in futs.mitems():
        discard sync(f)

template withSenderSerial(txs: openArray[Transaction], body: untyped) =
  for txIndex {.inject.}, tx {.inject.} in txs:
    let sender {.inject.} = tx.recoverSender().valueOr(default(Address))
    body

template withSender(vmState: BaseVMState, txs: openArray[Transaction], body: untyped) =
  when compileOption("threads"):
    if not vmState.com.taskpool.isNil() and vmState.com.taskpool.numThreads > 1:
      withSenderParallel(vmState, txs, body)
    else:
      withSenderSerial(txs, body)
  else:
    withSenderSerial(txs, body)

template withBalPrefetch(
    vmState: BaseVMState, bal: Opt[BlockAccessListRef], body: untyped) =
  when compileOption("threads"):
    if ((bal.isSome() and vmState.com.balStatePrefetch and vmState.com.isAmsterdamOrLater(vmState.blockCtx.timestamp)) or
      (bal.isSome() and vmState.com.balStatePrefetchForce)) and
        not vmState.com.taskpool.isNil() and vmState.com.taskpool.numThreads > 1:
      vmState.balPrefetchActive = true
      withBalPrefetchParallel(vmState, bal, body)
    else:
      body
  else:
    body

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
        vmState.ledger.addBalance(withdrawal.address, withdrawal.weiAmount, checkEmptyAccount = false)
    else:
      for withdrawal in blk.withdrawals.get:
        vmState.ledger.addBalance(withdrawal.address, withdrawal.weiAmount, checkEmptyAccount = false)
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

  # Commit block access list tracker changes for post‑execution system calls
  if vmState.balTrackerEnabled:
    vmState.balTracker.commitCallFrame()

  if not skipValidation:
    if not skipPostExecBalCheck and vmState.com.isAmsterdamOrLater(header.timestamp):
      doAssert vmState.balTrackerEnabled

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
    blockAccessList = Opt.none(BlockAccessListRef),
    skipValidation = false,
    skipReceipts = false,
    skipUncles = false,
    skipStateRootCheck = false,
    skipPostExecBalCheck = false,
): Result[void, string] =
  ## Generalised function to processes `blk` for any network.

  vmState.withBalPrefetch(blockAccessList):
    ?vmState.procBlkPreamble(blk, skipValidation, skipReceipts, skipUncles)

    # EIP-3675: no reward for miner in POA/POS
    if not vmState.com.proofOfStake(blk.header, vmState.ledger.txFrame):
      vmState.calculateReward(blk.header, blk.uncles)

    ?vmState.procBlkEpilogue(blk, skipValidation, skipReceipts, skipStateRootCheck, skipPostExecBalCheck)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
