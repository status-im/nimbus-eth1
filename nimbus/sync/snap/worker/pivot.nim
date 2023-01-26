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


proc init(
    T: type SnapRangeBatchRef;      # Collection of sets of account ranges
    ctx: SnapCtxRef;                # Some global context
      ): T =
  ## Account ranges constructor
  new result
  result.unprocessed.init() # full range on the first set of the pair
  result.processed = NodeTagRangeSet.init()

  # Update coverage level roll over
  ctx.pivotAccountsCoverage100PcRollOver()

  # Initialise accounts range fetch batch, the pair of `fetchAccounts[]` range
  # sets. Deprioritise already processed ranges by moving it to the second set.
  for iv in ctx.data.coveredAccounts.increasing:
    discard result.unprocessed[0].reduce iv
    discard result.unprocessed[1].merge iv

proc init(
    T: type SnapPivotRef;           # Privot descriptor type
    ctx: SnapCtxRef;                # Some global context
    header: BlockHeader;            # Header to generate new pivot from
      ): T =
  ## Pivot constructor.
  result = T(
    stateHeader:   header,
    fetchAccounts: SnapRangeBatchRef.init(ctx))
  result.storageAccounts.init()

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


proc reverseUpdate*(
    pivotTable: var SnapPivotTable; # Pivot table
    header: BlockHeader;            # Header to generate new pivot from
    ctx: SnapCtxRef;                # Some global context
      ) =
  ## Activate environment for earlier state root implied by `header` argument.
  ##
  ## Note that the pivot table is assumed to be sorted by the block numbers of
  ## the pivot header.
  ##
  # Append per-state root environment to LRU queue
  discard pivotTable.prepend(
    header.stateRoot, SnapPivotRef.init(ctx, header))

  # Make sure that the LRU table does not grow too big.
  if max(3, ctx.buddiesMax) < pivotTable.len:
    # Delete second entry rather than the first which might currently
    # be needed.
    let rc = pivotTable.secondKey
    if rc.isOk:
      pivotTable.del rc.value


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

  result = proc: SnapTickerStats =
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
      beaconBlock = none(BlockNumber)
      pivotBlock = none(BlockNumber)
      stoQuLen = none(int)
      procChunks = 0
    if not env.isNil:
      pivotBlock = some(env.stateHeader.blockNumber)
      procChunks = env.fetchAccounts.processed.chunks
      stoQuLen = some(env.storageQueueTotal())
    if 0 < ctx.data.beaconHeader.blockNumber:
      beaconBlock = some(ctx.data.beaconHeader.blockNumber)

    SnapTickerStats(
      beaconBlock:   beaconBlock,
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
    ctx.pivotAccountsCoverage100PcRollOver()

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

  if fa.processed.isEmpty:
    return err(NoAccountsYet)

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
    ctx.pivotAccountsCoverage100PcRollOver() # update coverage level roll over

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

proc pivotApprovePeer*(buddy: SnapBuddyRef) {.async.} =
  ## Approve peer and update pivot. On failure, the `buddy` will be stopped so
  ## it will not proceed to the next scheduler task.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    beaconHeader = ctx.data.beaconHeader
  var
    pivotHeader: BlockHeader

  block:
    let rc = ctx.data.pivotTable.lastValue
    if rc.isOk:
      pivotHeader = rc.value.stateHeader

  # Check whether the pivot needs to be updated
  if pivotHeader.blockNumber + pivotBlockDistanceMin < beaconHeader.blockNumber:
    # If the entry before the previous entry is unused, then run a pool mode
    # based session (which should enable a pivot table purge).
    block:
      let rc = ctx.data.pivotTable.beforeLast
      if rc.isOk and rc.value.data.fetchAccounts.processed.isEmpty:
        ctx.poolMode = true

    when extraTraceMessages:
      trace "New pivot from beacon chain", peer,
        pivot=("#" & $pivotHeader.blockNumber),
        beacon=("#" & $beaconHeader.blockNumber), poolMode=ctx.poolMode

    discard ctx.data.pivotTable.lruAppend(
      beaconHeader.stateRoot, SnapPivotRef.init(ctx, beaconHeader),
      pivotTableLruEntriesMax)

    pivotHeader = beaconHeader

  # Not ready yet?
  if pivotHeader.blockNumber == 0:
    buddy.ctrl.stopped = true


proc pivotUpdateBeaconHeaderCB*(ctx: SnapCtxRef): SyncReqNewHeadCB =
  ## Update beacon header. This function is intended as a call back function
  ## for the RPC module.
  result = proc(h: BlockHeader) {.gcsafe.} =
    if ctx.data.beaconHeader.blockNumber < h.blockNumber:
      # when extraTraceMessages:
      #   trace "External beacon info update", header=("#" & $h.blockNumber)
      ctx.data.beaconHeader = h

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
