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
  bearssl/rand,
  chronos,
  eth/[common, trie/trie_defs],
  stew/[interval_set, keyed_queue, sorted_set],
  ../../sync_desc,
  ".."/[constants, range_desc, worker_desc],
  ./db/[hexary_error, snapdb_accounts, snapdb_pivot],
  ./pivot/[heal_accounts, heal_storage_slots,
           range_fetch_accounts, range_fetch_storage_slots],
  ./ticker

{.push raises: [Defect].}

const
  extraAsserts = false or true
    ## Enable some asserts

proc pivotAccountsHealingOk*(env: SnapPivotRef;ctx: SnapCtxRef): bool {.gcsafe.}
proc pivotAccountsComplete*(env: SnapPivotRef): bool {.gcsafe.}
proc pivotMothball*(env: SnapPivotRef) {.gcsafe.}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc init(
    batch: SnapRangeBatchRef;
    stateRoot: Hash256;
    ctx: SnapCtxRef;
      ) =
  ## Returns a pair of account hash range lists with the full range of hashes
  ## smartly spread across the mutually disjunct interval sets.
  batch.unprocessed.init()
  batch.processed = NodeTagRangeSet.init()

  # Once applicable when the hexary trie is non-empty, healing is started on
  # the full range of all possible accounts. So the partial path batch list
  # is initialised with the empty partial path encoded as `@[0]` which refers
  # to the first (typically `Branch`) node. The envelope of `@[0]` covers the
  # maximum range of accounts.
  #
  # Note that `@[]` incidentally has the same effect as `@[0]` although it
  # is formally no partial path.
  batch.nodes.check.add NodeSpecs(
    partialPath: @[0.byte],
    nodeKey:     stateRoot.to(NodeKey))

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
    if rc.isOk and rc.value.pivotAccountsHealingOk(ctx):
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
    var topEnv = env

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

      # Update healing threshold for top pivot entry
      topEnv = pivotTable.lastValue.value

    else:
      discard pivotTable.lruAppend(
        header.stateRoot, env, pivotTableLruEntriesMax)

    # Update healing threshold
    let
      slots = max(0, healAccountsPivotTriggerNMax - pivotTable.len)
      delta = slots.float * healAccountsPivotTriggerWeight
    topEnv.healThresh = healAccountsPivotTriggerMinFactor + delta


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
      accCoverage = ctx.data.coveredAccounts.fullFactor
      accFill = meanStdDev(uSum, uSqSum, count)
    var
      pivotBlock = none(BlockNumber)
      stoQuLen = none(int)
      accStats = (0,0,0)
    if not env.isNil:
      pivotBlock = some(env.stateHeader.blockNumber)
      stoQuLen = some(env.fetchStorageFull.len + env.fetchStoragePart.len)
      accStats = (env.fetchAccounts.processed.chunks,
                  env.fetchAccounts.nodes.check.len,
                  env.fetchAccounts.nodes.missing.len)

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

proc pivotMothball*(env: SnapPivotRef) =
  ## Clean up most of this argument `env` pivot record and mark it `archived`.
  ## Note that archived pivots will be checked for swapping in already known
  ## accounts and storage slots.
  env.fetchAccounts.nodes.check.setLen(0)
  env.fetchAccounts.nodes.missing.setLen(0)
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


proc pivotAccountsComplete*(
    env: SnapPivotRef;              # Current pivot environment
      ): bool =
  ## Returns `true` if accounts are fully available for this this pivot.
  env.fetchAccounts.processed.isFull

proc pivotAccountsHealingOk*(
    env: SnapPivotRef;              # Current pivot environment
    ctx: SnapCtxRef;                # Some global context
      ): bool =
  ## Returns `true` if accounts healing is enabled for this pivot.
  ##
  if not env.pivotAccountsComplete():
    # Only start accounts healing if there is some completion level, already.
    #
    # We check against the global coverage factor, i.e. a measure for how much
    # of the total of all accounts have been processed. Even if the hexary trie
    # database for the current pivot state root is sparsely filled, there is a
    # good chance that it can inherit some unchanged sub-trie from an earlier
    # pivot state root download. The healing process then works like sort of
    # glue.
    if healAccountsCoverageTrigger <= ctx.data.coveredAccounts.fullFactor:
      # Ditto for pivot.
      if env.healThresh <= env.fetchAccounts.processed.fullFactor:
        return true


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
    if snapStorageSlotsQuPrioThresh < nStoQu:
      await buddy.rangeFetchStorageSlots(env)
      if buddy.ctrl.stopped or env.archived:
        return

  if not env.pivotAccountsComplete():
    await buddy.rangeFetchAccounts(env)

    # Run at least one round fetching storage slosts even if the `archived`
    # flag is set in order to keep the batch queue small.
    if not buddy.ctrl.stopped:
      await buddy.rangeFetchStorageSlots(env)

    if buddy.ctrl.stopped or env.archived:
      return

    if env.pivotAccountsHealingOk(ctx):
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
  if env.pivotAccountsHealingOk(ctx):
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
    nStoQu = env.fetchStorageFull.len + env.fetchStoragePart.len

  if snapAccountsSaveProcessedChunksMax < fa.processed.chunks:
    return err(TooManyProcessedChunks)

  if snapAccountsSaveStorageSlotsMax < nStoQu:
    return err(TooManySlotAccounts)

  ctx.data.snapDb.savePivot SnapDbPivotRegistry(
    header:       env.stateHeader,
    nAccounts:    env.nAccounts,
    nSlotLists:   env.nSlotLists,
    processed:    toSeq(env.fetchAccounts.processed.increasing)
                    .mapIt((it.minPt,it.maxPt)),
    slotAccounts: (toSeq(env.fetchStorageFull.nextKeys) &
                   toSeq(env.fetchStoragePart.nextKeys)).mapIt(it.to(NodeKey)))


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
    let pt = NodeTagRange.new(w.to(NodeTag),w.to(NodeTag))

    if 0 < env.fetchAccounts.processed.covered(pt):
      # Ignoring slots that have accounts to be downloaded, anyway
      let rc = ctx.data.snapDb.getAccountsData(stateRoot, w)
      if rc.isErr:
        # Oops, how did that account get lost?
        discard env.fetchAccounts.processed.reduce pt
        env.fetchAccounts.unprocessed.merge pt
      elif rc.value.storageRoot != emptyRlpHash:
        env.fetchStorageFull.merge AccountSlotsHeader(
          accKey:      w,
          storageRoot: rc.value.storageRoot)

  # Handle mothballed pivots for swapping in (see `pivotMothball()`)
  if not topLevel:
    for kvp in env.fetchStorageFull.nextPairs:
      let rc = env.storageAccounts.insert(kvp.data.accKey.to(NodeTag))
      if rc.isOk:
        rc.value.data = kvp.key
    env.archived = true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
