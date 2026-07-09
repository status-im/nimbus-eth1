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
  std/[atomics, algorithm],
  ../../common/common,
  ../../db/ledger,
  ../../db/core_db,
  ../../transaction,
  ../../evm/state,
  ../../evm/types,
  ../../evm/precompiles,
  ../../evm/interpreter/gas_costs,
  ../../block_access_list/[bal_builder, bal_overlay, bal_tracker, bal_utils],
  ../../concurrency/[shared_types, utils],
  ../eip7691,
  ./process_transaction,
  ./executor_helpers,
  eth/common/transaction_utils,
  taskpools,
  results,
  stew/assign2

type
  OptimisticPrefetchCtx* = object
    com: CommonRef
    txFrame: CoreDbTxRef
    parent: Header
    blockCtx: BlockContext
    cancelled: Atomic[bool]

  OptimisticTxEntry* = object
    tx: ptr Transaction
    sender: Address
    senderReady: Atomic[bool]

  BalPrefetchCtx* = object
    txFrame: CoreDbTxRef
    fork: EVMFork
    balPtr: ptr BlockAccessList
    nextIndex: Atomic[int]
    cancelled: Atomic[bool]

  BalParallelTxCtx = object
    com: CommonRef
    txFrame: CoreDbTxRef
    parent: Header
    blockCtx: BlockContext
    balPtr: ptr BlockAccessList
    sharedBuilder: ptr BlockAccessListBuilder
    cancelled: Atomic[bool]

  BalParallelTxEntry = object
    tx: ptr Transaction
    txIndex: int
    gasUsed: GasInt
    blockRegularGasUsed: GasInt
    blockStateGasUsed: GasInt
    intrinsic: IntrinsicGas
    blobGasUsed: uint64
    status: bool
    logs: SharedBytes
    error: SharedString
    preempted: bool

proc recoverAndPrefetchTask*(
    ctx: ptr OptimisticPrefetchCtx, e: ptr OptimisticTxEntry): bool {.nimcall.} =
  # Recover the sender from the signature. `default(Address)` signals sig
  # check failure.
  let sender = e[].tx[].recoverSender().valueOr(default(Address))
  e[].sender = sender
  e[].senderReady.store(true, moRelease)

  # When ctx is non-nil, optimistic state prefetch is enabled
  if ctx.isNil() or sender == default(Address) or ctx[].cancelled.load(moAcquire):
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
  vmState.prefetchTransaction(e[].tx[], sender)

  true

template withSenderParallel*(
    vmState: BaseVMState, txs: openArray[Transaction],
    bal: Opt[BlockAccessListRef], body: untyped) =
  # Execute transactions offloading the signature checking to the task pool
  var
    entries = newSeq[OptimisticTxEntry](txs.len)
    futs = newSeq[Flowvar[bool]](txs.len)
    ctx: OptimisticPrefetchCtx
    ctxPtr: ptr OptimisticPrefetchCtx = nil

  # Skip optimistic state prefetch when block access list prefetch is running
  # to avoid prefetching the same state twice.
  if vmState.com.optimisticStatePrefetchEnabled() and
      not vmState.com.balStatePrefetchEnabled(vmState.blockCtx.timestamp, bal):
    ctx.parent = vmState.parent
    ctx.blockCtx = vmState.blockCtx
    ctx.com = vmState.com
    # Run the prefetch on the parent frame because the current frame will
    # be writen to during block execution and this way we avoid having to
    # use locking on the frame data structures.
    ctx.txFrame = vmState.ledger.txFrame.parent()
    ctx.cancelled.store(false, moRelease)
    ctxPtr = ctx.addr

  # Spawn one task per transaction that recovers the sender and, when ctxPtr
  # is non-nil, also performs an optimistic state prefetch. Spawning here
  # allows the task to start early, while we still haven't processed subsequent txs.
  for i, e in entries.mpairs():
    e.tx = txs[i].addr
    let entryPtr = e.addr
    futs[i] = vmState.com.taskpool.spawn recoverAndPrefetchTask(
      ctxPtr, entryPtr)

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
      ctxPtr[].cancelled.store(true, moRelease)
    # Wait for all tasks to complete before returning so that no task
    # outlives the local data it references.
    for f in futs.mitems():
      discard sync(f)

func firstBalIndex(sc: SlotChanges): BlockAccessIndex =
  ## Earliest block access index at which the slot was written.
  ## Block access list validation guarantees `changes` is non-empty.
  assert sc.changes.len > 0
  sc.changes[0].blockAccessIndex

proc balPrefetchWorker*(ctx: ptr BalPrefetchCtx): bool {.nimcall.} =
  let len = ctx[].balPtr[].len
  while true:
    if ctx[].cancelled.load(moAcquire):
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

template withBalPrefetchParallel*(
    vmState: BaseVMState, bal: Opt[BlockAccessListRef], body: untyped) =

  let balRef = bal.get()

  var ctx: BalPrefetchCtx
  ctx.balPtr = balRef[].addr
  # Read through the parent frame because the current frame is written to
  # during block execution; this avoids locking on the frame data structures.
  ctx.txFrame = vmState.ledger.txFrame.parent()
  ctx.fork = vmState.fork
  ctx.nextIndex.store(0, moRelease)
  ctx.cancelled.store(false, moRelease)

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
    ctxPtr[].cancelled.store(true, moRelease)
    for f in futs.mitems():
      discard sync(f)

proc applyBlockAccessListState(ledger: LedgerRef, bal: BlockAccessList, txCount: int) =
  let boundary = txCount + 1

  for accChanges in bal:
    let address = accChanges.address

    var balanceZeroed = false
    let balancePos = accChanges.balanceChanges.findLastWriteBefore(boundary)
    if balancePos >= 0:
      let postBalance = accChanges.balanceChanges[balancePos].postBalance
      ledger.setBalance(address, postBalance)
      balanceZeroed = postBalance.isZero

    let noncePos = accChanges.nonceChanges.findLastWriteBefore(boundary)
    if noncePos >= 0:
      ledger.setNonce(address, accChanges.nonceChanges[noncePos].newNonce)

    let codePos = accChanges.codeChanges.findLastWriteBefore(boundary)
    if codePos >= 0:
      ledger.setCode(address, accChanges.codeChanges[codePos].newCode)

    for slotChanges in accChanges.storageChanges:
      let changePos = slotChanges.changes.findLastWriteBefore(boundary)
      if changePos >= 0:
        ledger.setStorage(
          address, slotChanges.slot, slotChanges.changes[changePos].newValue)

    if balanceZeroed:
      ledger.addBalance(address, 0.u256, checkEmptyAccount = true)

proc packLogs(logs: openArray[Log]): SharedBytes =
  var size = sizeof(uint32)
  for log in logs:
    size +=
      sizeof(Address) + sizeof(uint32) + log.topics.len * sizeof(Topic) +
      sizeof(uint32) + log.data.len

  var
    packed = SharedBytes.init(size)
    pos = 0

  template put(src: pointer, n: int) =
    copyMem(addr packed[pos], src, n)
    pos += n

  template putLen(v: int) =
    var x = uint32(v)
    put(addr x, sizeof(uint32))

  putLen(logs.len)
  for log in logs:
    put(unsafeAddr log.address, sizeof(Address))
    putLen(log.topics.len)
    for topic in log.topics:
      put(unsafeAddr topic, sizeof(Topic))
    putLen(log.data.len)
    if log.data.len > 0:
      put(unsafeAddr log.data[0], log.data.len)

  packed

proc unpackLogs(buf: openArray[byte]): seq[Log] =
  var pos = 0

  template get(dst: pointer, n: int) =
    copyMem(dst, unsafeAddr buf[pos], n)
    pos += n

  template getLen(): int =
    var x: uint32
    get(addr x, sizeof(uint32))
    int(x)

  var logs = newSeq[Log](getLen())
  for log in logs.mitems:
    get(addr log.address, sizeof(Address))
    log.topics = newSeq[Topic](getLen())
    for topic in log.topics.mitems:
      get(addr topic, sizeof(Topic))
    log.data = newSeq[byte](getLen())
    if log.data.len > 0:
      get(addr log.data[0], log.data.len)

  logs

proc processTxTask(
    ctx: ptr BalParallelTxCtx, e: ptr BalParallelTxEntry
): bool {.nimcall.} =
  if ctx[].cancelled.load(moAcquire):
    # Another task has already failed and cancelled the block.
    e[].preempted = true
    return false

  let sender = e[].tx[].recoverSender().valueOr:
    e[].error = SharedString.init("could not recover sender")
    ctx[].cancelled.store(true, moRelease)
    return false

  # Create the ledger without triggering a ref count increment on the txFrame
  # which is owned by the main/parent thread.
  let ledger = LedgerRef()
  ledger.txFrame.borrowRef(ctx[].txFrame)
  defer:
    ledger.txFrame.unborrowRef()
  ledger.balOverlay = Opt.some(BlockAccessListOverlay.init(ctx[].balPtr, e[].txIndex + 1))
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
  if not ctx[].sharedBuilder.isNil():
    vmState.balTracker =
      BlockAccessListTrackerRef.init(ledger.ReadOnlyLedger, ctx[].sharedBuilder)
    vmState.balTracker.setBlockAccessIndex(e[].txIndex + 1)

  let logResult = vmState.processTransaction(e[].tx[], sender, persist = false).valueOr:
    e[].error = SharedString.init(error)
    ctx[].cancelled.store(true, moRelease)
    return false

  e[].gasUsed = logResult.gasUsed
  e[].blockRegularGasUsed = vmState.blockRegularGasUsed
  e[].blockStateGasUsed = vmState.blockStateGasUsed
  e[].intrinsic = e[].tx[].intrinsicGas(vmState.hardFork, vmState.blockCtx.gasLimit, sender)
  e[].blobGasUsed = vmState.blobGasUsed
  e[].status = vmState.status
  e[].logs = packLogs(logResult.logEntries)

  true

proc processTransactionsParallel*(
    vmState: BaseVMState,
    transactions: seq[Transaction],
    balRef: BlockAccessListRef,
    skipReceipts: bool,
    collectLogs: bool,
): Result[void, string] =
  doAssert vmState.fork >= FkAmsterdam
  doAssert not vmState.com.statelessProvider

  let n = transactions.len()

  var
    ctx: BalParallelTxCtx
    entries = newSeq[BalParallelTxEntry](n)
    futs = newSeq[Flowvar[bool]](n)

  ctx.com = vmState.com
  ctx.txFrame = vmState.ledger.txFrame
  ctx.parent = vmState.parent
  ctx.blockCtx = vmState.blockCtx
  ctx.balPtr = balRef[].addr
  ctx.sharedBuilder =
    if vmState.balTrackerEnabled:
      vmState.balTracker.builder
    else:
      nil

  for i in 0 ..< n:
    entries[i].tx = transactions[i].addr
    entries[i].txIndex = i
    futs[i] = vmState.com.taskpool.spawn processTxTask(
      ctx.addr, entries[i].addr)

  # Number of tasks already synced. On an early return the remaining tasks must
  # still be synced before their entry/ctx data goes out of scope, otherwise a
  # still running task would reference freed memory and leak its Flowvar.
  var synced = 0
  defer:
    while synced < n:
      discard sync(futs[synced])
      inc synced
    for i in 0 ..< n:
      entries[i].logs.dispose()
      entries[i].error.dispose()

  # Process each result as soon as its task completes so the main thread makes
  # progress while the remaining tasks keep running in the background.
  for i in 0 ..< n:
    let ok = sync(futs[i])
    inc synced
    if not ok:
      # find the task that caused the failure
      var failIdx = i
      while entries[failIdx].preempted and failIdx + 1 < n:
        inc failIdx
        discard sync(futs[failIdx])
        inc synced
      return err(
        "Error processing tx with index " & $failIdx & ":" &
        entries[failIdx].error.toString())

    block:
      template fail(msg: string) =
        ctx.cancelled.store(true, moRelease)
        return err("Error processing tx with index " & $i & ":" & msg)

      check2dGasInclusion(vmState, transactions[i].gasLimit, fail)

    vmState.cumulativeGasUsed += entries[i].gasUsed
    vmState.blockRegularGasUsed += entries[i].blockRegularGasUsed
    vmState.blockStateGasUsed += entries[i].blockStateGasUsed
    vmState.blobGasUsed += entries[i].blobGasUsed
    vmState.status = entries[i].status

    # Enforce the block gas limit on the running total so that an invalid
    # over-limit block is rejected as early as possible, cancelling the
    # remaining tasks instead of executing every transaction.
    if vmState.blockCtx.gasLimit <
        max(vmState.blockRegularGasUsed, vmState.blockStateGasUsed):
      ctx.cancelled.store(true, moRelease)
      return err(
        "Error processing tx with index " & $i & ": block gas limit reached (2D). " &
        "gasLimit=" & $vmState.blockCtx.gasLimit &
        ", regularGas=" & $vmState.blockRegularGasUsed &
        ", stateGas=" & $vmState.blockStateGasUsed)

    var logs = unpackLogs(entries[i].logs.data(asOpenArray = true))
    if skipReceipts:
      if collectLogs:
        vmState.allLogs.add logs
    else:
      vmState.receipts[i] =
        vmState.makeReceipt(transactions[i].txType, LogResult(logEntries: move(logs)))
      if collectLogs:
        vmState.allLogs.add vmState.receipts[i].logs

  let maxBlobGasPerBlock = getMaxBlobGasPerBlock(vmState.com, vmState.hardFork)
  if vmState.blobGasUsed > maxBlobGasPerBlock:
    return err(
      "blobGasUsed " & $vmState.blobGasUsed & " exceeds maximum allowance " &
      $maxBlobGasPerBlock)

  applyBlockAccessListState(vmState.ledger, balRef[], n)
  ok()
