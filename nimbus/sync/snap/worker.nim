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
  std/[hashes, math, options, sets],
  chronicles,
  chronos,
  eth/[common/eth_types, p2p],
  stew/[interval_set, keyed_queue],
  ../../db/select_backend,
  ".."/[protocol, sync_desc],
  ./worker/[heal_accounts, store_accounts, store_storages, ticker],
  ./worker/com/[com_error, get_block_header],
  ./worker/db/snap_db,
  "."/[range_desc, worker_desc]

const
  usePivot2ok = false or true

when usePivot2ok:
  import
    ../misc/best_pivot
  type
    PivotCtxRef = BestPivotCtxRef
    PivotWorkerRef = BestPivotWorkerRef
else:
  import
    ../../p2p/chain/chain_desc,
    ../misc/snap_pivot
  type
    PivotCtxRef = SnapPivotCtxRef
    PivotWorkerRef = SnapPivotWorkerRef

{.push raises: [Defect].}

logScope:
  topics = "snap-sync"

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

proc pivot(ctx: SnapCtxRef): PivotCtxRef =
  # Getter
  ctx.data.pivotFinderCtx.PivotCtxRef

proc `pivot=`(ctx: SnapCtxRef; val: PivotCtxRef) =
  # Setter
  ctx.data.pivotFinderCtx = val

proc pivot(buddy: SnapBuddyRef): PivotWorkerRef =
  # Getter
  buddy.data.pivotFinder.PivotWorkerRef

proc `pivot=`(buddy: SnapBuddyRef; val: PivotWorkerRef) =
  # Setter
  buddy.data.pivotFinder = val

# --------------------

proc pivotSetup(ctx: SnapCtxRef) =
  when usePivot2ok:
    ctx.pivot = PivotCtxRef.init(ctx.data.rng)
  else:
    ctx.pivot = PivotCtxRef.init(ctx, ctx.chain.Chain)

proc pivotRelease(ctx: SnapCtxRef) =
  ctx.pivot = nil

proc pivotStart(buddy: SnapBuddyRef) =
  buddy.pivot = PivotWorkerRef.init(buddy.ctx.pivot, buddy.ctrl, buddy.peer)

proc pivotStop(buddy: SnapBuddyRef) =
  buddy.pivot.clear()

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc init(T: type SnapAccountRanges; ctx: SnapCtxRef): T =
  ## Return a pair of account hash range lists with the whole range of
  ## smartly spread `[low(NodeTag),high(NodeTag)]` across the mutually
  ## disjunct interval sets.
  result = [LeafRangeSet.init(),LeafRangeSet.init()]

  # Initialise accounts range fetch batch, the pair of `fetchAccounts[]`
  # range sets.
  if ctx.data.coveredAccounts.total == 0 and
     ctx.data.coveredAccounts.chunks == 1:
    # 100% of accounts covered by range fetch batches for the total
    # of pivot environments. Do a random split distributing the range
    # `[low(NodeTag),high(NodeTag)]` across the pair of range sats.
    var nodeKey: NodeKey
    ctx.data.rng[].generate(nodeKey.ByteArray32)

    let partition = nodeKey.to(NodeTag)
    discard result[0].merge(partition, high(NodeTag))
    if low(NodeTag) < partition:
      discard result[1].merge(low(NodeTag), partition - 1.u256)
  else:
    # Not all account hashes are covered, yet. So keep the uncovered
    # account hashes in the first range set, and the other account hashes
    # in the second range set.

    # Pre-filled with thefirst range set with largest possible interval
    discard result[0].merge(low(NodeTag),high(NodeTag))

    # Move covered account ranges (aka intervals) to the second set.
    for iv in ctx.data.coveredAccounts.increasing:
      discard result[0].reduce(iv)
      discard result[1].merge(iv)


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
      if rc.isOk: rc.value.stateHeader.blockNumber + minPivotBlockDistance
      else: 1.toBlockNumber

  # Check whether the new header follows minimum depth requirement. This is
  # where the queue is assumed to have increasing block numbers.
  if minNumber <= header.blockNumber:
    # Ok, append a new environment
    let env = SnapPivotRef(
      stateHeader:   header,
      fetchAccounts: SnapAccountRanges.init(ctx))

    # Append per-state root environment to LRU queue
    discard ctx.data.pivotTable.lruAppend(header.stateRoot, env, ctx.buddiesMax)

    # Debugging, will go away
    block:
      let ivSet = env.fetchAccounts[0].clone
      for iv in env.fetchAccounts[1].increasing:
        doAssert ivSet.merge(iv) == iv.len
      doAssert ivSet.chunks == 1
      doAssert ivSet.total == 0


proc updatePivotImpl(buddy: SnapBuddyRef): Future[bool] {.async.} =
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
    when noPivotEnvChangeIfComplete:
      let rc = ctx.data.pivotTable.lastValue
      if rc.isOk and rc.value.serialSync:
        # No neede to change
        if extraTraceMessages:
          trace "No need to change snap pivot", peer,
            pivot=("#" & $rc.value.stateHeader.blockNumber),
            multiOk=buddy.ctrl.multiOk, runState=buddy.ctrl.state
        return true

    when 0 < backPivotBlockDistance:
      # Backtrack, do not use the very latest pivot header
      if backPivotBlockThreshold.toBlockNumber < header.blockNumber:
        let
          backNum = header.blockNumber - backPivotBlockDistance.toBlockNumber
          rc = await buddy.getBlockHeader(backNum)
        if rc.isErr:
          if rc.error in {ComNoHeaderAvailable, ComTooManyHeaders}:
            buddy.ctrl.zombie = true
          return false
        header = rc.value

    buddy.appendPivotEnv(header)

    trace "Snap pivot initialised", peer, pivot=("#" & $header.blockNumber),
      multiOk=buddy.ctrl.multiOk, runState=buddy.ctrl.state

    return true

# Syntactic sugar
when usePivot2ok:
  template updateSinglePivot(buddy: SnapBuddyRef): auto =
    buddy.updatePivotImpl()
else:
  template updateMultiPivot(buddy: SnapBuddyRef): auto =
    buddy.updatePivotImpl()


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
        let fill = kvp.data.fetchAccounts.emptyFactor
        uSum += fill
        uSqSum += fill * fill

        let sLen = kvp.data.nStorage.float
        sSum += sLen
        sSqSum += sLen * sLen

    let
      env = ctx.data.pivotTable.lastValue.get(otherwise = nil)
      pivotBlock = if env.isNil: none(BlockNumber)
                   else: some(env.stateHeader.blockNumber)
      accCoverage = ctx.data.coveredAccounts.fullFactor
      accFill = meanStdDev(uSum, uSqSum, count)

    TickerStats(
      pivotBlock:    pivotBlock,
      nQueues:       ctx.data.pivotTable.len,
      nAccounts:     meanStdDev(aSum, aSqSum, count),
      nStorage:      meanStdDev(sSum, sSqSum, count),
      accountsFill:  (accFill[0], accFill[1], accCoverage))

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc setup*(ctx: SnapCtxRef; tickerOK: bool): bool =
  ## Global set up
  ctx.data.coveredAccounts = LeafRangeSet.init()
  ctx.data.snapDb =
    if ctx.data.dbBackend.isNil: SnapDbRef.init(ctx.chain.getTrieDB)
    else: SnapDbRef.init(ctx.data.dbBackend)
  ctx.pivotSetup()
  if tickerOK:
    ctx.data.ticker = TickerRef.init(ctx.tickerUpdate)
  else:
    trace "Ticker is disabled"
  result = true

proc release*(ctx: SnapCtxRef) =
  ## Global clean up
  ctx.pivotRelease()
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
    buddy.pivotStart()
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
  buddy.pivotStop()
  if not ctx.data.ticker.isNil:
    ctx.data.ticker.stopBuddy()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc runSingle*(buddy: SnapBuddyRef) {.async.} =
  ## This peer worker is invoked if the peer-local flag `buddy.ctrl.multiOk`
  ## is set `false` which is the default mode. This flag is updated by the
  ## worker when deemed appropriate.
  ## * For all workers, there can be only one `runSingle()` function active
  ##   simultaneously for all worker peers.
  ## * There will be no `runMulti()` function active for the same worker peer
  ##   simultaneously
  ## * There will be no `runPool()` iterator active simultaneously.
  ##
  ## Note that this function runs in `async` mode.
  ##
  when usePivot2ok:
    # Run alternative pivot finder. This one harmonises difficulties of at
    # least two peers. The can only be one instance active/unfinished of the
    # `pivot2Exec()` functions.
    let peer = buddy.peer
    if not await buddy.updateSinglePivot():
      # Wait if needed, then return => repeat
      if not buddy.ctrl.stopped:
        await sleepAsync(2.seconds)
      return

  buddy.ctrl.multiOk = true


proc runPool*(buddy: SnapBuddyRef, last: bool) =
  ## Ocne started, the function `runPool()` is called for all worker peers in
  ## a row (as the body of an iteration.) There will be no other worker peer
  ## functions activated simultaneously.
  ##
  ## This procedure is started if the global flag `buddy.ctx.poolMode` is set
  ## `true` (default is `false`.) It is the responsibility of the `runPool()`
  ## instance to reset the flag `buddy.ctx.poolMode`, typically at the first
  ## peer instance.
  ##
  ## The argument `last` is set `true` if the last entry is reached.
  ##
  ## Note that this function does not run in `async` mode.
  ##
  let ctx = buddy.ctx
  if ctx.poolMode:
    ctx.poolMode = false

    let rc = ctx.data.pivotTable.lastValue
    if rc.isOk:
      # Check whether accounts and storage might be complete.
      let env = rc.value
      if not env.serialSync:
        # Check whether accounts download is complete
        block checkAccountsComplete:
          for ivSet in env.fetchAccounts:
            if ivSet.chunks != 0:
              break checkAccountsComplete
          env.accountsDone = true
          # Check whether storage slots are complete
          if env.fetchStorage.len == 0:
            env.serialSync = true


proc runMulti*(buddy: SnapBuddyRef) {.async.} =
  ## This peer worker is invoked if the `buddy.ctrl.multiOk` flag is set
  ## `true` which is typically done after finishing `runSingle()`. This
  ## instance can be simultaneously active for all peer workers.
  ##
  let
    ctx = buddy.ctx
    peer = buddy.peer

  when not usePivot2ok:
    discard await buddy.updateMultiPivot()

  # Set up current state root environment for accounts snapshot
  let env = block:
    let rc = ctx.data.pivotTable.lastValue
    if rc.isErr:
      return # nothing to do
    rc.value

  buddy.data.pivotEnv = env

  if env.serialSync:
    trace "Snap serial sync -- not implemented yet", peer
    await sleepAsync(5.seconds)

  else:
    # Snapshot sync processing. Note that *serialSync => accountsDone*.
    await buddy.storeStorages() # always pre-clean the queue
    await buddy.storeAccounts()
    await buddy.storeStorages()

    # If the current database is not complete yet
    if 0 < env.fetchAccounts[0].chunks or
       0 < env.fetchAccounts[1].chunks:

      # Healing applies to the latest pivot only. The pivot might have changed
      # in the background (while netwoking) due to a new peer worker that has
      # negotiated another, newer pivot.
      if env == ctx.data.pivotTable.lastValue.value:

        # Only start healing if there is some data already on the database
        # and the coverage factor is large enough
        if 0 < env.nAccounts:
          if healAccountsTrigger <= ctx.data.coveredAccounts.fullFactor:
            await buddy.healAccountsDb()

      # TODO: use/apply storage healer

      # Check whether accounts might be complete.
      if env.fetchStorage.len == 0:
        # Possibly done but some buddies might wait for an account range to be
        # received from the network. So we need to sync.
        buddy.ctx.poolMode = true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
