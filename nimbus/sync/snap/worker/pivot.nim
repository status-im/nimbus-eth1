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
  std/[math, sets, sequtils, strutils],
  chronicles,
  chronos,
  eth/[common, p2p, trie/trie_defs],
  stew/[interval_set, keyed_queue, sorted_set],
  ../../sync_desc,
  ".."/[constants, range_desc, worker_desc],
  ./db/[hexary_error, snapdb_accounts, snapdb_pivot],
  ./pivot/[heal_accounts, heal_storage_slots,
           range_fetch_accounts, range_fetch_storage_slots,
           storage_queue_helper],
  ./ticker

{.push raises: [Defect].}

logScope:
  topics = "snap-pivot"

const
  extraAsserts = false or true
    ## Enable some asserts

  extraTraceMessages = false or true
    ## Enabled additional logging noise

proc pivotMothball*(env: SnapPivotRef) {.gcsafe.}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc accountsHealingOk(
    env: SnapPivotRef;              # Current pivot environment
    ctx: SnapCtxRef;                # Some global context
      ): bool =
  ## Returns `true` if accounts healing is enabled for this pivot.
  not env.fetchAccounts.processed.isEmpty and
    healAccountsCoverageTrigger <= ctx.pivotAccountsCoverage()


proc coveredAccounts100PcRollOver(
    ctx: SnapCtxRef;
      ) =
  ## Roll over `coveredAccounts` registry when it reaches 100%.
  if ctx.data.coveredAccounts.isFull:
    # All of accounts hashes are covered by completed range fetch processes
    # for all pivot environments. So reset covering and record full-ness level.
    ctx.data.covAccTimesFull.inc
    ctx.data.coveredAccounts.clear()


proc init(
    batch: SnapRangeBatchRef;
    stateRoot: Hash256;
    ctx: SnapCtxRef;
      ) =
  ## Returns a pair of account hash range lists with the full range of hashes
  ## smartly spread across the mutually disjunct interval sets.
  batch.unprocessed.init() # full range on the first set of the pair
  batch.processed = NodeTagRangeSet.init()

  # Initialise accounts range fetch batch, the pair of `fetchAccounts[]`
  # range sets.
  ctx.coveredAccounts100PcRollOver()

  # Deprioritise already processed ranges by moving it to the second set.
  for iv in ctx.data.coveredAccounts.increasing:
    discard batch.unprocessed[0].reduce iv
    discard batch.unprocessed[1].merge iv

  when extraAsserts:
    doAssert batch.unprocessed.verify

# ------------------------------------------------------------------------------
# Public functions: pivot table related
# ------------------------------------------------------------------------------

proc beforeTopMostlyClean*(pivotTable: var SnapPivotTable) =
  ## Clean up pivot queues of the entry before the top one. The queues are
  ## the pivot data that need most of the memory. This cleaned pivot is not
  ## usable any more after cleaning but might be useful as historic record.
  let rc = pivotTable.beforeLastValue
  if rc.isOk:
    rc.value.pivotMothball


proc topNumber*(pivotTable: var SnapPivotTable): BlockNumber =
  ## Return the block number of the top pivot entry, or zero if there is none.
  let rc = pivotTable.lastValue
  if rc.isOk:
    return rc.value.stateHeader.blockNumber


proc update*(
    pivotTable: var SnapPivotTable; # Pivot table
    header: BlockHeader;            # Header to generate new pivot from
    ctx: SnapCtxRef;                # Some global context
    reverse = false;                # Update from bottom (e.g. for recovery)
      ) =
  ## Activate environment for state root implied by `header` argument. This
  ## function appends a new environment unless there was any not far enough
  ## apart.
  ##
  ## Note that the pivot table is assumed to be sorted by the block numbers of
  ## the pivot header.
  ##
  # Calculate minimum block distance.
  let minBlockDistance = block:
    let rc = pivotTable.lastValue
    if rc.isOk and rc.value.accountsHealingOk(ctx):
      pivotBlockDistanceThrottledPivotChangeMin
    else:
      pivotBlockDistanceMin

  # Check whether the new header follows minimum depth requirement. This is
  # where the queue is assumed to have increasing block numbers.
  if reverse or
     pivotTable.topNumber() + pivotBlockDistanceMin < header.blockNumber:

    # Ok, append a new environment
    let env = SnapPivotRef(
      stateHeader:   header,
      fetchAccounts: SnapRangeBatchRef())
    env.fetchAccounts.init(header.stateRoot, ctx)
    env.storageAccounts.init()

    # Append per-state root environment to LRU queue
    if reverse:
      discard pivotTable.prepend(header.stateRoot, env)
      # Make sure that the LRU table does not grow too big.
      if max(3, ctx.buddiesMax) < pivotTable.len:
        # Delete second entry rather thanthe first which might currently
        # be needed.
        let rc = pivotTable.secondKey
        if rc.isOk:
          pivotTable.del rc.value
    else:
      discard pivotTable.lruAppend(
        header.stateRoot, env, pivotTableLruEntriesMax)


proc tickerStats*(
    pivotTable: var SnapPivotTable; # Pivot table
    ctx: SnapCtxRef;                # Some global context
      ): TickerStatsUpdater =
  ## This function returns a function of type `TickerStatsUpdater` that prints
  ## out pivot table statitics. The returned fuction is supposed to drive
  ## ticker` module.
  proc meanStdDev(sum, sqSum: float; length: int): (float,float) =
    if 0 < length:
      result[0] = sum / length.float
      result[1] = sqrt(sqSum / length.float - result[0] * result[0])

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
        let fill = kvp.data.fetchAccounts.processed.fullFactor
        uSum += fill
        uSqSum += fill * fill

        let sLen = kvp.data.nSlotLists.float
        sSum += sLen
        sSqSum += sLen * sLen
    let
      env = ctx.data.pivotTable.lastValue.get(otherwise = nil)
      accCoverage = (ctx.data.coveredAccounts.fullFactor +
                     ctx.data.covAccTimesFull.float)
      accFill = meanStdDev(uSum, uSqSum, count)
    var
      pivotBlock = none(BlockNumber)
      stoQuLen = none(int)
      procChunks = 0
    if not env.isNil:
      pivotBlock = some(env.stateHeader.blockNumber)
      procChunks = env.fetchAccounts.processed.chunks
      stoQuLen = some(env.storageQueueTotal())

    TickerStats(
      pivotBlock:    pivotBlock,
      nQueues:       ctx.data.pivotTable.len,
      nAccounts:     meanStdDev(aSum, aSqSum, count),
      nSlotLists:    meanStdDev(sSum, sSqSum, count),
      accountsFill:  (accFill[0], accFill[1], accCoverage),
      nAccountStats: procChunks,
      nStorageQueue: stoQuLen)

# ------------------------------------------------------------------------------
# Public functions: particular pivot
# ------------------------------------------------------------------------------

proc pivotMothball*(env: SnapPivotRef) =
  ## Clean up most of this argument `env` pivot record and mark it `archived`.
  ## Note that archived pivots will be checked for swapping in already known
  ## accounts and storage slots.
  env.fetchAccounts.unprocessed.init()

  # Simplify storage slots queues by resolving partial slots into full list
  for kvp in env.fetchStoragePart.nextPairs:
    discard env.fetchStorageFull.append(
      kvp.key, SnapSlotsQueueItemRef(acckey: kvp.data.accKey))
  env.fetchStoragePart.clear()

  # Provide index into `fetchStorageFull`
  env.storageAccounts.clear()
  for kvp in env.fetchStorageFull.nextPairs:
    let rc = env.storageAccounts.insert(kvp.data.accKey.to(NodeTag))
    # Note that `rc.isErr` should not exist as accKey => storageRoot
    if rc.isOk:
      rc.value.data = kvp.key

  # Finally, mark that node `archived`
  env.archived = true


proc execSnapSyncAction*(
    env: SnapPivotRef;              # Current pivot environment
    buddy: SnapBuddyRef;            # Worker peer
      ) {.async.} =
  ## Execute a synchronisation run.
  let
    ctx = buddy.ctx

  block:
    # Clean up storage slots queue first it it becomes too large
    let nStoQu = env.fetchStorageFull.len + env.fetchStoragePart.len
    if storageSlotsQuPrioThresh < nStoQu:
      await buddy.rangeFetchStorageSlots(env)
      if buddy.ctrl.stopped or env.archived:
        return

  if not env.fetchAccounts.processed.isFull:
    await buddy.rangeFetchAccounts(env)

    # Update 100% accounting
    ctx.coveredAccounts100PcRollOver()

    # Run at least one round fetching storage slosts even if the `archived`
    # flag is set in order to keep the batch queue small.
    if not buddy.ctrl.stopped:
      await buddy.rangeFetchStorageSlots(env)

    if buddy.ctrl.stopped or env.archived:
      return

    if env.accountsHealingOk(ctx):
      await buddy.healAccounts(env)
      if buddy.ctrl.stopped or env.archived:
        return

  # Some additional storage slots might have been popped up
  await buddy.rangeFetchStorageSlots(env)
  if buddy.ctrl.stopped or env.archived:
    return

  # Don't bother with storage slots healing before accounts healing takes
  # place. This saves communication bandwidth. The pivot might change soon,
  # anyway.
  if env.accountsHealingOk(ctx):
    await buddy.healStorageSlots(env)


proc saveCheckpoint*(
    env: SnapPivotRef;              # Current pivot environment
    ctx: SnapCtxRef;                # Some global context
      ): Result[int,HexaryError] =
  ## Save current sync admin data. On success, the size of the data record
  ## saved is returned (e.g. for logging.)
  ##
  let
    fa = env.fetchAccounts
    nStoQu = env.storageQueueTotal()

  if accountsSaveProcessedChunksMax < fa.processed.chunks:
    return err(TooManyProcessedChunks)

  if accountsSaveStorageSlotsMax < nStoQu:
    return err(TooManySlotAccounts)

  ctx.data.snapDb.savePivot SnapDbPivotRegistry(
    header:       env.stateHeader,
    nAccounts:    env.nAccounts,
    nSlotLists:   env.nSlotLists,
    processed:    toSeq(env.fetchAccounts.processed.increasing)
                    .mapIt((it.minPt,it.maxPt)),
    slotAccounts: (toSeq(env.fetchStorageFull.nextKeys) &
                   toSeq(env.fetchStoragePart.nextKeys)).mapIt(it.to(NodeKey)) &
                   toSeq(env.parkedStorage.items))


proc recoverPivotFromCheckpoint*(
    env: SnapPivotRef;              # Current pivot environment
    ctx: SnapCtxRef;                # Global context (containing save state)
    topLevel: bool;                 # Full data set on top level only
      ) =
  ## Recover some pivot variables and global list `coveredAccounts` from
  ## checkpoint data. If the argument `toplevel` is set `true`, also the
  ## `processed`, `unprocessed`, and the `fetchStorageFull` lists are
  ## initialised.
  ##
  let recov = ctx.data.recovery
  if recov.isNil:
    return

  env.nAccounts = recov.state.nAccounts
  env.nSlotLists = recov.state.nSlotLists

  # Import processed interval
  for (minPt,maxPt) in recov.state.processed:
    if topLevel:
      env.fetchAccounts.unprocessed.reduce(minPt, maxPt)
    discard env.fetchAccounts.processed.merge(minPt, maxPt)
    discard ctx.data.coveredAccounts.merge(minPt, maxPt)

  # Handle storage slots
  let stateRoot = recov.state.header.stateRoot
  for w in recov.state.slotAccounts:
    let pt = NodeTagRange.new(w.to(NodeTag),w.to(NodeTag)) # => `pt.len == 1`

    if 0 < env.fetchAccounts.processed.covered(pt):
      # Ignoring slots that have accounts to be downloaded, anyway
      let rc = ctx.data.snapDb.getAccountsData(stateRoot, w)
      if rc.isErr:
        # Oops, how did that account get lost?
        discard env.fetchAccounts.processed.reduce pt
        env.fetchAccounts.unprocessed.merge pt
      elif rc.value.storageRoot != emptyRlpHash:
        env.storageQueueAppendFull(rc.value.storageRoot, w)

  # Handle mothballed pivots for swapping in (see `pivotMothball()`)
  if not topLevel:
    for kvp in env.fetchStorageFull.nextPairs:
      let rc = env.storageAccounts.insert(kvp.data.accKey.to(NodeTag))
      if rc.isOk:
        rc.value.data = kvp.key
    env.archived = true

# ------------------------------------------------------------------------------
# Public function, manage new peer and pivot update
# ------------------------------------------------------------------------------

proc pivotUpdateBeaconHeaderCB*(ctx: SnapCtxRef): SyncReqNewHeadCB =
  ## Update beacon header. This function is intended as a call back function
  ## for the RPC module.
  result = proc(number: BlockNumber; hash: Hash256) {.gcsafe.} =
    if ctx.data.beaconNumber < number:
      when extraTraceMessages:
        trace "External beacon info update", number, hash
      ctx.data.beaconNumber = number
      ctx.data.beaconHash = hash

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
