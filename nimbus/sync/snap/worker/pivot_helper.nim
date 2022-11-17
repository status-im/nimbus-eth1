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
  std/[math, sequtils],
  chronos,
  eth/[common, p2p],
  stew/[interval_set, keyed_queue],
  ../../sync_desc,
  ".."/[constants, range_desc, worker_desc],
  ./db/[hexary_error, snapdb_pivot],
  "."/[heal_accounts, heal_storage_slots,
       range_fetch_accounts, range_fetch_storage_slots, ticker]

{.push raises: [Defect].}

const
  extraAsserts = false or true
    ## Enable some asserts

# ------------------------------------------------------------------------------
# Private helpers
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
      # Move already processed account ranges (aka intervals) to the second set.
      discard batch.unprocessed[0].reduce iv
      discard batch.unprocessed[1].merge iv

  when extraAsserts:
    if batch.unprocessed[0].isEmpty:
      doAssert batch.unprocessed[1].isFull
    elif batch.unprocessed[1].isEmpty:
      doAssert batch.unprocessed[0].isFull
    else:
      doAssert((batch.unprocessed[0].total - 1) +
               batch.unprocessed[1].total == high(UInt256))

# ------------------------------------------------------------------------------
# Public functions: pivot table related
# ------------------------------------------------------------------------------

proc beforeTopMostlyClean*(pivotTable: var SnapPivotTable) =
  ## Clean up pivot queues of the entry before the top one. The queues are
  ## the pivot data that need most of the memory. This cleaned pivot is not
  ## usable any more after cleaning but might be useful as historic record.
  let rc = pivotTable.beforeLastValue
  if rc.isOk:
    let env = rc.value
    env.fetchStorageFull.clear()
    env.fetchStoragePart.clear()
    env.fetchAccounts.checkNodes.setLen(0)
    env.fetchAccounts.sickSubTries.setLen(0)
    env.obsolete = true


proc topNumber*(pivotTable: var SnapPivotTable): BlockNumber =
  ## Return the block number op the top pivot entry, or zero if there is none.
  let rc = pivotTable.lastValue
  if rc.isOk:
    return rc.value.stateHeader.blockNumber


proc update*(
    pivotTable: var SnapPivotTable; ## Pivot table
    header: BlockHeader;            ## Header to generate new pivot from
    ctx: SnapCtxRef;                ## Some global context
      ) =
  ## Activate environment for state root implied by `header` argument. This
  ## function appends a new environment unless there was any not far enough
  ## apart.
  ##
  ## Note that the pivot table is assumed to be sorted by the block numbers of
  ## the pivot header.
  ##
  # Check whether the new header follows minimum depth requirement. This is
  # where the queue is assumed to have increasing block numbers.
  if pivotTable.topNumber() + pivotBlockDistanceMin < header.blockNumber:

    # Ok, append a new environment
    let env = SnapPivotRef(stateHeader: header)
    env.fetchAccounts.init(ctx)

    # Append per-state root environment to LRU queue
    discard pivotTable.lruAppend(header.stateRoot, env, ctx.buddiesMax)


proc tickerStats*(
    pivotTable: var SnapPivotTable; ## Pivot table
    ctx: SnapCtxRef;                ## Some global context
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
        let fill = kvp.data.fetchAccounts.unprocessed.emptyFactor
        uSum += fill
        uSqSum += fill * fill

        let sLen = kvp.data.nSlotLists.float
        sSum += sLen
        sSqSum += sLen * sLen

    let
      env = ctx.data.pivotTable.lastValue.get(otherwise = nil)
      accCoverage = ctx.data.coveredAccounts.fullFactor
      accFill = meanStdDev(uSum, uSqSum, count)
    var
      pivotBlock = none(BlockNumber)
      stoQuLen = none(int)
      accStats = (0,0)
    if not env.isNil:
      pivotBlock = some(env.stateHeader.blockNumber)
      stoQuLen = some(env.fetchStorageFull.len + env.fetchStoragePart.len)
      accStats = (env.fetchAccounts.unprocessed[0].chunks +
                  env.fetchAccounts.unprocessed[1].chunks,
                  env.fetchAccounts.sickSubTries.len)

    TickerStats(
      pivotBlock:    pivotBlock,
      nQueues:       ctx.data.pivotTable.len,
      nAccounts:     meanStdDev(aSum, aSqSum, count),
      nSlotLists:    meanStdDev(sSum, sSqSum, count),
      accountsFill:  (accFill[0], accFill[1], accCoverage),
      nAccountStats: accStats,
      nStorageQueue: stoQuLen)

# ------------------------------------------------------------------------------
# Public functions: particular pivot
# ------------------------------------------------------------------------------

proc execSnapSyncAction*(
    env: SnapPivotRef;              ## Current pivot environment
    buddy: SnapBuddyRef;            ## Worker peer
      ): Future[bool]
      {.async.} =
  ## Execute a synchronisation run. The return code is `true` if a full
  ## synchronisation cycle could be executed.
  let
    ctx = buddy.ctx

  block:
    # Clean up storage slots queue first it it becomes too large
    let nStoQu = env.fetchStorageFull.len + env.fetchStoragePart.len
    if snapStorageSlotsQuPrioThresh < nStoQu:
      await buddy.rangeFetchStorageSlots(env)
      if buddy.ctrl.stopped or env.obsolete:
        return false

  if env.accountsState != HealerDone:
    await buddy.rangeFetchAccounts(env)
    if buddy.ctrl.stopped or env.obsolete:
      return false

    await buddy.rangeFetchStorageSlots(env)
    if buddy.ctrl.stopped or env.obsolete:
      return false

    if not ctx.data.accountsHealing:
      # Only start healing if there is some completion level, already.
      #
      # We check against the global coverage factor, i.e. a measure for how
      # much of the total of all accounts have been processed. Even if the
      # hexary trie database for the current pivot state root is sparsely
      # filled, there is a good chance that it can inherit some unchanged
      # sub-trie from an earlier pivor state root download. The healing
      # process then works like sort of glue.
      if 0 < env.nAccounts:
        if healAccountsTrigger <= ctx.data.coveredAccounts.fullFactor:
          ctx.data.accountsHealing = true

    if ctx.data.accountsHealing:
      # Can only run a single accounts healer instance at a time. This
      # instance will clear the batch queue so there is nothing to do for
      # another process.
      if env.accountsState == HealerIdle:
        env.accountsState = HealerRunning
        await buddy.healAccounts(env)
        env.accountsState = HealerIdle

        if buddy.ctrl.stopped or env.obsolete:
          return false

      # Some additional storage slots might have been popped up
      await buddy.rangeFetchStorageSlots(env)
      if buddy.ctrl.stopped or env.obsolete:
        return false

  await buddy.healStorageSlots(env)
  if buddy.ctrl.stopped or env.obsolete:
    return false

  return true


proc saveCheckpoint*(
    env: SnapPivotRef;              ## Current pivot environment
    ctx: SnapCtxRef;                ## Some global context
      ): Result[int,HexaryDbError] =
  ## Save current sync admin data. On success, the size of the data record
  ## saved is returned (e.g. for logging.)
  if snapAccountsSaveDanglingMax < env.fetchAccounts.sickSubTries.len:
    return err(TooManyDanglingLinks)

  let nStoQu = env.fetchStorageFull.len + env.fetchStoragePart.len
  if snapAccountsSaveStorageSlotsMax < nStoQu:
    return err(TooManySlotAccounts)

  let
    rc = ctx.data.snapDb.savePivot(
    env.stateHeader, env.nAccounts, env.nSlotLists,
    dangling = env.fetchAccounts.sickSubTries.mapIt(it.partialPath),
    slotAccounts = toSeq(env.fetchStorageFull.nextKeys).mapIt(it.to(NodeKey)) &
                   toSeq(env.fetchStoragePart.nextKeys).mapIt(it.to(NodeKey)),
    coverage = (ctx.data.coveredAccounts.fullFactor * 255).uint8)

  if rc.isErr:
    return err(rc.error)

  ok(rc.value)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
