# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/[hashes, math, options, sets, strutils],
  chronicles,
  chronos,
  eth/[common, p2p],
  stew/[interval_set, keyed_queue],
  ../../db/select_backend,
  ".."/[handlers, misc/best_pivot, protocol, sync_desc],
  ./worker/[heal_accounts, heal_storage_slots,
            range_fetch_accounts, range_fetch_storage_slots, ticker],
  ./worker/com/com_error,
  ./worker/db/[snapdb_check, snapdb_desc],
  "."/[constants, range_desc, worker_desc]

{.push raises: [Defect].}

logScope:
  topics = "snap-buddy"

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc meanStdDev(sum, sqSum: float; length: int): (float,float) =
  if 0 < length:
    result[0] = sum / length.float
    result[1] = sqrt(sqSum / length.float - result[0] * result[0])

template noExceptionOops(info: static[string]; code: untyped) =
  try:
    code
  except CatchableError as e:
    raiseAssert "Inconveivable (" & info & ": name=" & $e.name & " msg=" & e.msg
  except Defect as e:
    raise e
  except Exception as e:
    raiseAssert "Ooops " & info & ": name=" & $e.name & " msg=" & e.msg

# ------------------------------------------------------------------------------
# Private helpers: integration of pivot finder
# ------------------------------------------------------------------------------

proc pivot(ctx: SnapCtxRef): BestPivotCtxRef =
  # Getter
  ctx.data.pivotFinderCtx.BestPivotCtxRef

proc `pivot=`(ctx: SnapCtxRef; val: BestPivotCtxRef) =
  # Setter
  ctx.data.pivotFinderCtx = val

proc pivot(buddy: SnapBuddyRef): BestPivotWorkerRef =
  # Getter
  buddy.data.pivotFinder.BestPivotWorkerRef

proc `pivot=`(buddy: SnapBuddyRef; val: BestPivotWorkerRef) =
  # Setter
  buddy.data.pivotFinder = val

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc init(batch: var SnapTrieRangeBatch; ctx: SnapCtxRef) =
  ## Returns a pair of account hash range lists with the full range of hashes
  ## smartly spread across the mutually disjunct interval sets.
  batch.unprocessed.init()

  # Initialise accounts range fetch batch, the pair of `fetchAccounts[]`
  # range sets.
  if ctx.data.coveredAccounts.isFull:
    # All of accounts hashes are covered by completed range fetch processes
    # for all pivot environments. Do a random split distributing the full
    # accounts hash range across the pair of range sets.
    for _ in 0 .. 5:
      var nodeKey: NodeKey
      ctx.data.rng[].generate(nodeKey.ByteArray32)
      let top = nodeKey.to(NodeTag)
      if low(NodeTag) < top and top < high(NodeTag):
        # Move covered account ranges (aka intervals) to the second set.
        batch.unprocessed.merge NodeTagRange.new(low(NodeTag), top)
        break
      # Otherwise there is a full single range in `unprocessed[0]`
  else:
    # Not all account hashes are covered, yet. So keep the uncovered
    # account hashes in the first range set, and the other account hashes
    # in the second range set.
    for iv in ctx.data.coveredAccounts.increasing:
      # Move covered account ranges (aka intervals) to the second set.
      batch.unprocessed.merge(iv)

  if batch.unprocessed[0].isEmpty:
    doAssert batch.unprocessed[1].isFull
  elif batch.unprocessed[1].isEmpty:
    doAssert batch.unprocessed[0].isFull
  else:
    doAssert((batch.unprocessed[0].total - 1) +
             batch.unprocessed[1].total == high(UInt256))


proc appendPivotEnv(buddy: SnapBuddyRef; header: BlockHeader) =
  ## Activate environment for state root implied by `header` argument. This
  ## function appends a new environment unless there was any not far enough
  ## apart.
  ##
  ## Note that this function relies on a queue sorted by the block numbers of
  ## the pivot header. To maintain the sort order, the function `lruFetch()`
  ## must not be called and only records appended with increasing block
  ## numbers.
  let
    ctx = buddy.ctx
    minNumber = block:
      let rc = ctx.data.pivotTable.lastValue
      if rc.isOk: rc.value.stateHeader.blockNumber + pivotBlockDistanceMin
      else: 1.toBlockNumber

  # Check whether the new header follows minimum depth requirement. This is
  # where the queue is assumed to have increasing block numbers.
  if minNumber <= header.blockNumber:
    # Ok, append a new environment
    let env = SnapPivotRef(stateHeader: header)
    env.fetchAccounts.init(ctx)

    # Append per-state root environment to LRU queue
    discard ctx.data.pivotTable.lruAppend(header.stateRoot, env, ctx.buddiesMax)


proc updateSinglePivot(buddy: SnapBuddyRef): Future[bool] {.async.} =
  ## Helper, negotiate pivot unless present
  if buddy.pivot.pivotHeader.isOk:
    return true

  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = ctx.data.pivotTable.lastValue.get(otherwise = nil)
    nMin = if env.isNil: none(BlockNumber)
           else: some(env.stateHeader.blockNumber)

  if await buddy.pivot.pivotNegotiate(nMin):
    var header = buddy.pivot.pivotHeader.value

    # Check whether there is no environment change needed
    when pivotEnvStopChangingIfComplete:
      let rc = ctx.data.pivotTable.lastValue
      if rc.isOk and rc.value.storageDone:
        # No neede to change
        if extraTraceMessages:
          trace "No need to change snap pivot", peer,
            pivot=("#" & $rc.value.stateHeader.blockNumber),
            stateRoot=rc.value.stateHeader.stateRoot,
            multiOk=buddy.ctrl.multiOk, runState=buddy.ctrl.state
        return true

    buddy.appendPivotEnv(header)

    info "Snap pivot initialised", peer, pivot=("#" & $header.blockNumber),
      multiOk=buddy.ctrl.multiOk, runState=buddy.ctrl.state

    return true


proc tickerUpdate*(ctx: SnapCtxRef): TickerStatsUpdater =
  result = proc: TickerStats =
    var
      aSum, aSqSum, uSum, uSqSum, sSum, sSqSum: float
      count = 0
    for kvp in ctx.data.pivotTable.nextPairs:

      # Accounts mean & variance
      let aLen = kvp.data.nAccounts.float
      if 0 < aLen:
        count.inc
        aSum += aLen
        aSqSum += aLen * aLen

        # Fill utilisation mean & variance
        let fill = kvp.data.fetchAccounts.unprocessed.emptyFactor
        uSum += fill
        uSqSum += fill * fill

        let sLen = kvp.data.nSlotLists.float
        sSum += sLen
        sSqSum += sLen * sLen

    let
      env = ctx.data.pivotTable.lastValue.get(otherwise = nil)
      pivotBlock = if env.isNil: none(BlockNumber)
                   else: some(env.stateHeader.blockNumber)
      stoQuLen = if env.isNil: none(uint64)
                 else: some(env.fetchStorageFull.len.uint64 +
                            env.fetchStoragePart.len.uint64)
      accCoverage = ctx.data.coveredAccounts.fullFactor
      accFill = meanStdDev(uSum, uSqSum, count)

    TickerStats(
      pivotBlock:    pivotBlock,
      nQueues:       ctx.data.pivotTable.len,
      nAccounts:     meanStdDev(aSum, aSqSum, count),
      nSlotLists:    meanStdDev(sSum, sSqSum, count),
      accountsFill:  (accFill[0], accFill[1], accCoverage),
      nStorageQueue: stoQuLen)

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc setup*(ctx: SnapCtxRef; tickerOK: bool): bool =
  ## Global set up
  # I have implemented tx exchange in
  # eth wire handler. Need the txpool
  # enabled. --andri
  #noExceptionOops("worker.setup()"):
    #ctx.ethWireCtx.txPoolEnabled(false)
  ctx.data.coveredAccounts = NodeTagRangeSet.init()
  ctx.data.snapDb =
    if ctx.data.dbBackend.isNil: SnapDbRef.init(ctx.chain.db.db)
    else: SnapDbRef.init(ctx.data.dbBackend)
  ctx.pivot = BestPivotCtxRef.init(ctx.data.rng)
  ctx.pivot.pivotRelaxedMode(enable = true)
  if tickerOK:
    ctx.data.ticker = TickerRef.init(ctx.tickerUpdate)
  else:
    trace "Ticker is disabled"
  result = true

proc release*(ctx: SnapCtxRef) =
  ## Global clean up
  ctx.pivot = nil
  if not ctx.data.ticker.isNil:
    ctx.data.ticker.stop()
    ctx.data.ticker = nil

proc start*(buddy: SnapBuddyRef): bool =
  ## Initialise worker peer
  let
    ctx = buddy.ctx
    peer = buddy.peer
  if peer.supports(protocol.snap) and
     peer.supports(protocol.eth) and
     peer.state(protocol.eth).initialized:
    buddy.pivot = BestPivotWorkerRef.init(
      buddy.ctx.pivot, buddy.ctrl, buddy.peer)
    buddy.data.errors = ComErrorStatsRef()
    if not ctx.data.ticker.isNil:
      ctx.data.ticker.startBuddy()
    return true

proc stop*(buddy: SnapBuddyRef) =
  ## Clean up this peer
  let
    ctx = buddy.ctx
    peer = buddy.peer
  buddy.ctrl.stopped = true
  buddy.pivot.clear()
  if not ctx.data.ticker.isNil:
    ctx.data.ticker.stopBuddy()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc runDaemon*(ctx: SnapCtxRef) {.async.} =
  ## Enabled while `ctx.daemon` is `true`
  ##
  let nPivots = ctx.data.pivotTable.len
  trace "I am the mighty recovery daemon ... stopped for now", nPivots
  # To be populated ...
  ctx.daemon = false


proc runSingle*(buddy: SnapBuddyRef) {.async.} =
  ## Enabled while
  ## * `buddy.ctrl.multiOk` is `false`
  ## * `buddy.ctrl.poolMode` is `false`
  ##
  let peer = buddy.peer
  # This pivot finder one harmonises assigned difficulties of at least two
  # peers. There can only be one  `pivot2Exec()` instance active/unfinished
  # (which is wrapped into the helper function `updateSinglePivot()`.)
  if not await buddy.updateSinglePivot():
    # Wait if needed, then return => repeat
    if not buddy.ctrl.stopped:
      await sleepAsync(2.seconds)
    return

  buddy.ctrl.multiOk = true


proc runPool*(buddy: SnapBuddyRef, last: bool) =
  ## Enabled when `buddy.ctrl.poolMode` is `true`
  ##
  let ctx = buddy.ctx
  if ctx.poolMode:
    ctx.poolMode = false

    let rc = ctx.data.pivotTable.lastValue
    if rc.isOk:

      # Check whether last pivot accounts and storage are complete.
      let
        env = rc.value
        peer = buddy.peer
        pivot = "#" & $env.stateHeader.blockNumber # for logging

      if not env.storageDone:

        # Check whether accounts download is complete
        if env.fetchAccounts.unprocessed.isEmpty():

          # FIXME: This check might not be needed. It will visit *every* node
          #        in the hexary trie for checking the account leaves.
          #
          #        Note: This is insane on main net
          if buddy.checkAccountsTrieIsComplete(env):
            env.accountsState = HealerDone

            # Check whether storage slots are complete
            if env.fetchStorageFull.len == 0 and
               env.fetchStoragePart.len == 0:
              env.storageDone = true

      if extraTraceMessages:
        trace "Checked for pivot DB completeness", peer, pivot,
          nAccounts=env.nAccounts, accountsState=env.accountsState,
          nSlotLists=env.nSlotLists, storageDone=env.storageDone


proc runMulti*(buddy: SnapBuddyRef) {.async.} =
  ## Enabled while
  ## * `buddy.ctrl.multiOk` is `true`
  ## * `buddy.ctrl.poolMode` is `false`
  ##
  let
    ctx = buddy.ctx
    peer = buddy.peer

  # Set up current state root environment for accounts snapshot
  let
    env = block:
      let rc = ctx.data.pivotTable.lastValue
      if rc.isErr:
        return # nothing to do
      rc.value
    pivot = "#" & $env.stateHeader.blockNumber # for logging

  buddy.data.pivotEnv = env

  # Full sync processsing based on current snapshot
  # -----------------------------------------------
  if env.storageDone:
    if not buddy.checkAccountsTrieIsComplete(env):
      error "Ooops, all accounts fetched but DvnB still incomplete", peer, pivot

      if not buddy.checkStorageSlotsTrieIsComplete(env):
        error "Ooops, all storages fetched but DB still incomplete", peer, pivot

    trace "Snap full sync -- not implemented yet", peer, pivot
    await sleepAsync(5.seconds)
    return

  # Snapshot sync processing
  # ------------------------

  template runAsync(code: untyped) =
    await code
    if buddy.ctrl.stopped:
      # To be disconnected from peer.
      return
    if env != ctx.data.pivotTable.lastValue.value:
      # Pivot has changed, so restart with the latest one
      return

  # If this is a new pivot, the previous one can be partially cleaned up.
  # There is no point in keeping some older space consuming state data any
  # longer.
  block:
    let rc = ctx.data.pivotTable.beforeLastValue
    if rc.isOk:
      let nFetchStorage =
        rc.value.fetchStorageFull.len + rc.value.fetchStoragePart.len
      if 0 < nFetchStorage:
        trace "Cleaning up previous pivot", peer, pivot, nFetchStorage
        rc.value.fetchStorageFull.clear()
        rc.value.fetchStoragePart.clear()
      rc.value.fetchAccounts.checkNodes.setLen(0)
      rc.value.fetchAccounts.missingNodes.setLen(0)

  # Clean up storage slots queue first it it becomes too large
  let nStoQu = env.fetchStorageFull.len + env.fetchStoragePart.len
  if snapNewBuddyStoragesSlotsQuPrioThresh < nStoQu:
    runAsync buddy.rangeFetchStorageSlots()

  if env.accountsState != HealerDone:
    runAsync buddy.rangeFetchAccounts()
    runAsync buddy.rangeFetchStorageSlots()

    # Can only run a single accounts healer instance at a time. This instance
    # will clear the batch queue so there is nothing to do for another process.
    if env.accountsState == HealerIdle:
      env.accountsState = HealerRunning
      runAsync buddy.healAccounts()
      env.accountsState = HealerIdle

      # Some additional storage slots might have been popped up
      runAsync buddy.rangeFetchStorageSlots()

  runAsync buddy.healStorageSlots()

  # Check whether there are more accounts to fetch.
  #
  # Note that some other process might have temporarily borrowed from the
  # `fetchAccounts.unprocessed` list. Whether we are done can only be decided
  # if only a single buddy is active. S be it.
  if env.fetchAccounts.unprocessed.isEmpty():

    # Debugging log: analyse pivot against database
    warn "Analysing accounts database -- might be slow", peer, pivot
    discard buddy.checkAccountsListOk(env)

    # Check whether pivot download is complete.
    if env.fetchStorageFull.len == 0 and
       env.fetchStoragePart.len == 0:
      trace "Running pool mode for verifying completeness", peer, pivot
      buddy.ctx.poolMode = true

    # Debugging log: analyse pivot against database
    warn "Analysing storage slots database -- might be slow", peer, pivot
    discard buddy.checkStorageSlotsTrieIsComplete(env)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
