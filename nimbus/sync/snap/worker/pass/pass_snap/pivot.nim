# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[math, sets, sequtils],
  chronicles,
  chronos,
  eth/p2p, # trie/trie_defs],
  stew/[interval_set, keyed_queue, sorted_set],
  "../../../.."/[misc/ticker, sync_desc, types],
  "../../.."/[constants, range_desc],
  ../../db/[hexary_error, snapdb_accounts, snapdb_contracts, snapdb_pivot],
  ./helper/[accounts_coverage, storage_queue],
  "."/[heal_accounts, heal_storage_slots, range_fetch_accounts,
       range_fetch_contracts, range_fetch_storage_slots],
  ./snap_pass_desc

logScope:
  topics = "snap-pivot"

const
  extraTraceMessages = false # or true
    ## Enabled additional logging noise

proc pivotMothball*(env: SnapPivotRef) {.gcsafe.}

# ------------------------------------------------------------------------------
# Private helpers, logging
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Pivot " & info

template ignExceptionOops(info: static[string]; code: untyped) =
  try:
    code
  except CatchableError as e:
    trace logTxt "Ooops", `info`=info, name=($e.name), msg=(e.msg)

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc accountsHealingOk(
    env: SnapPivotRef;              # Current pivot environment
    ctx: SnapCtxRef;                # Some global context
      ): bool =
  ## Returns `true` if accounts healing is enabled for this pivot.
  not env.fetchAccounts.processed.isEmpty and
    healAccountsCoverageTrigger <= ctx.accountsCoverage()


proc init(
    T: type SnapPassRangeBatchRef;  # Collection of sets of account ranges
    ctx: SnapCtxRef;                # Some global context
      ): T =
  ## Account ranges constructor
  new result
  result.unprocessed.init() # full range on the first set of the pair
  result.processed = NodeTagRangeSet.init()

  # Update coverage level roll over
  ctx.accountsCoverage100PcRollOver()

  # Initialise accounts range fetch batch, the pair of `fetchAccounts[]` range
  # sets. Deprioritise already processed ranges by moving it to the second set.
  for iv in ctx.pool.pass.coveredAccounts.increasing:
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
    fetchAccounts: SnapPassRangeBatchRef.init(ctx))
  result.storageAccounts.init()

# ------------------------------------------------------------------------------
# Public functions: pivot table related
# ------------------------------------------------------------------------------

proc beforeTopMostlyClean*(pivotTable: var SnapPassPivotTable) =
  ## Clean up pivot queues of the entry before the top one. The queues are
  ## the pivot data that need most of the memory. This cleaned pivot is not
  ## usable any more after cleaning but might be useful as historic record.
  let rc = pivotTable.beforeLastValue
  if rc.isOk:
    rc.value.pivotMothball

proc topNumber*(pivotTable: var SnapPassPivotTable): BlockNumber =
  ## Return the block number of the top pivot entry, or zero if there is none.
  let rc = pivotTable.lastValue
  if rc.isOk:
    return rc.value.stateHeader.blockNumber


proc reverseUpdate*(
    pivotTable: var SnapPassPivotTable; # Pivot table
    header: BlockHeader;                # Header to generate new pivot from
    ctx: SnapCtxRef;                    # Some global context
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
    pivotTable: var SnapPassPivotTable; # Pivot table
    ctx: SnapCtxRef;                    # Some global context
      ): TickerSnapStatsUpdater =
  ## This function returns a function of type `TickerStatsUpdater` that prints
  ## out pivot table statitics. The returned fuction is supposed to drive
  ## ticker` module.
  proc meanStdDev(sum, sqSum: float; length: int): (float,float) =
    if 0 < length:
      result[0] = sum / length.float
      let
        sqSumAv = sqSum / length.float
        rSq = result[0] * result[0]
      if rSq < sqSumAv:
        result[1] = sqrt(sqSum / length.float - result[0] * result[0])

  result = proc: auto =
    var
      aSum, aSqSum, uSum, uSqSum, sSum, sSqSum, cSum, cSqSum: float
      count = 0
    for kvp in ctx.pool.pass.pivotTable.nextPairs:

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

        # Lists of missing contracts
        let cLen = kvp.data.nContracts.float
        cSum += cLen
        cSqSum += cLen * cLen
    let
      env = ctx.pool.pass.pivotTable.lastValue.get(otherwise = nil)
      accCoverage = (ctx.pool.pass.coveredAccounts.fullFactor +
                     ctx.pool.pass.covAccTimesFull.float)
      accFill = meanStdDev(uSum, uSqSum, count)
    var
      beaconBlock = none(BlockNumber)
      pivotBlock = none(BlockNumber)
      stoQuLen = none(int)
      ctraQuLen = none(int)
      procChunks = 0
    if not env.isNil:
      pivotBlock = some(env.stateHeader.blockNumber)
      procChunks = env.fetchAccounts.processed.chunks
      stoQuLen = some(env.storageQueueTotal())
      ctraQuLen = some(env.fetchContracts.len)
    if 0 < ctx.pool.pass.beaconHeader.blockNumber:
      beaconBlock = some(ctx.pool.pass.beaconHeader.blockNumber)

    TickerSnapStats(
      beaconBlock:    beaconBlock,
      pivotBlock:     pivotBlock,
      nQueues:        ctx.pool.pass.pivotTable.len,
      nAccounts:      meanStdDev(aSum, aSqSum, count),
      nSlotLists:     meanStdDev(sSum, sSqSum, count),
      nContracts:     meanStdDev(cSum, cSqSum, count),
      accountsFill:   (accFill[0], accFill[1], accCoverage),
      nAccountStats:  procChunks,
      nStorageQueue:  stoQuLen,
      nContractQueue: ctraQuLen)

# ------------------------------------------------------------------------------
# Public functions: particular pivot
# ------------------------------------------------------------------------------

proc pivotCompleteOk*(env: SnapPivotRef): bool =
  ## Returns `true` iff the pivot covers a complete set of accounts ans
  ## storage slots.
  env.fetchAccounts.processed.isFull and
    env.storageQueueTotal() == 0 and
    env.fetchContracts.len == 0


proc pivotMothball*(env: SnapPivotRef) =
  ## Clean up most of this argument `env` pivot record and mark it `archived`.
  ## Note that archived pivots will be checked for swapping in already known
  ## accounts and storage slots.
  env.fetchAccounts.unprocessed.init()

  # Simplify storage slots queues by resolving partial slots into full list
  for kvp in env.fetchStoragePart.nextPairs:
    discard env.fetchStorageFull.append(
      kvp.key, SnapPassSlotsQItemRef(acckey: kvp.data.accKey))
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

  if env.savedFullPivotOk:
    return # no need to do anything

  block:
    # Clean up storage slots queue and contracts first it becomes too large
    if storageSlotsQuPrioThresh < env.storageQueueAvail():
      await buddy.rangeFetchStorageSlots(env)
      if buddy.ctrl.stopped or env.archived:
        return
    if contractsQuPrioThresh < env.fetchContracts.len:
      await buddy.rangeFetchContracts(env)
      if buddy.ctrl.stopped or env.archived:
        return

  var rangeFetchOk = true
  if not env.fetchAccounts.processed.isFull:
    await buddy.rangeFetchAccounts(env)

    # Update 100% accounting
    ctx.accountsCoverage100PcRollOver()

    # Run at least one round fetching storage slosts and contracts even if
    # the `archived` flag is set in order to keep the batch queue small.
    if buddy.ctrl.running:
      await buddy.rangeFetchStorageSlots(env)
      await buddy.rangeFetchContracts(env)
    else:
      rangeFetchOk = false
    if env.archived or (buddy.ctrl.zombie and buddy.only.errors.peerDegraded):
      return

    # Uncconditonally try healing if enabled.
    if env.accountsHealingOk(ctx):
      # Let this procedure decide whether to ditch this peer (if any.) The idea
      # is that the healing process might address different peer ressources
      # than the fetch procedure. So that peer might still be useful unless
      # physically disconnected.
      buddy.ctrl.forceRun = true
      await buddy.healAccounts(env)
      if env.archived or (buddy.ctrl.zombie and buddy.only.errors.peerDegraded):
        return

  # Some additional storage slots and contracts might have been popped up
  if rangeFetchOk:
    await buddy.rangeFetchStorageSlots(env)
    await buddy.rangeFetchContracts(env)
    if env.archived:
      return

  # Don't bother with storage slots healing before accounts healing takes
  # place. This saves communication bandwidth. The pivot might change soon,
  # anyway.
  if env.accountsHealingOk(ctx):
    buddy.ctrl.forceRun = true
    await buddy.healStorageSlots(env)


proc saveCheckpoint*(
    env: SnapPivotRef;          # Current pivot environment
    ctx: SnapCtxRef;                # Some global context
      ): Result[int,HexaryError] =
  ## Save current sync admin data. On success, the size of the data record
  ## saved is returned (e.g. for logging.)
  ##
  if env.savedFullPivotOk:
    return ok(0) # no need to do anything

  let fa = env.fetchAccounts
  if fa.processed.isEmpty:
    return err(NoAccountsYet)

  if saveAccountsProcessedChunksMax < fa.processed.chunks:
    return err(TooManyChunksInAccountsQueue)

  if saveStorageSlotsMax < env.storageQueueTotal():
    return err(TooManyQueuedStorageSlots)

  if saveContactsMax < env.fetchContracts.len:
    return err(TooManyQueuedContracts)

  result = ctx.pool.snapDb.pivotSaveDB SnapDbPivotRegistry(
    header:       env.stateHeader,
    nAccounts:    env.nAccounts,
    nSlotLists:   env.nSlotLists,
    processed:    toSeq(env.fetchAccounts.processed.increasing)
                    .mapIt((it.minPt,it.maxPt)),
    slotAccounts: (toSeq(env.fetchStorageFull.nextKeys) &
                   toSeq(env.fetchStoragePart.nextKeys)).mapIt(it.to(NodeKey)) &
                   toSeq(env.parkedStorage.items),
    ctraAccounts: (toSeq(env.fetchContracts.nextValues)))

  if result.isOk and env.pivotCompleteOk():
    env.savedFullPivotOk = true


proc pivotRecoverFromCheckpoint*(
    env: SnapPivotRef;              # Current pivot environment
    ctx: SnapCtxRef;                # Global context (containing save state)
    topLevel: bool;                 # Full data set on top level only
      ) =
  ## Recover some pivot variables and global list `coveredAccounts` from
  ## checkpoint data. If the argument `toplevel` is set `true`, also the
  ## `processed`, `unprocessed`, and the `fetchStorageFull` lists are
  ## initialised.
  ##
  let recov = ctx.pool.pass.recovery
  if recov.isNil:
    return

  env.nAccounts = recov.state.nAccounts
  env.nSlotLists = recov.state.nSlotLists

  # Import processed interval
  for (minPt,maxPt) in recov.state.processed:
    if topLevel:
      env.fetchAccounts.unprocessed.reduce NodeTagRange.new(minPt, maxPt)
    discard env.fetchAccounts.processed.merge(minPt, maxPt)
    discard ctx.pool.pass.coveredAccounts.merge(minPt, maxPt)
    ctx.accountsCoverage100PcRollOver() # update coverage level roll over

  # Handle storage slots
  let stateRoot = recov.state.header.stateRoot
  for w in recov.state.slotAccounts:
    let pt = NodeTagRange.new(w.to(NodeTag),w.to(NodeTag)) # => `pt.len == 1`

    if 0 < env.fetchAccounts.processed.covered(pt):
      # Ignoring slots that have accounts to be downloaded, anyway
      let rc = ctx.pool.snapDb.getAccountsData(stateRoot, w)
      if rc.isErr:
        # Oops, how did that account get lost?
        discard env.fetchAccounts.processed.reduce pt
        env.fetchAccounts.unprocessed.merge pt
      elif rc.value.storageRoot != EMPTY_ROOT_HASH:
        env.storageQueueAppendFull(rc.value.storageRoot, w)

  # Handle contracts
  for w in recov.state.ctraAccounts:
    let pt = NodeTagRange.new(w.to(NodeTag),w.to(NodeTag)) # => `pt.len == 1`

    if 0 < env.fetchAccounts.processed.covered(pt):
      # Ignoring contracts that have accounts to be downloaded, anyway
      let rc = ctx.pool.snapDb.getAccountsData(stateRoot, w)
      if rc.isErr:
        # Oops, how did that account get lost?
        discard env.fetchAccounts.processed.reduce pt
        env.fetchAccounts.unprocessed.merge pt
      elif rc.value.codeHash != EMPTY_CODE_HASH:
        env.fetchContracts[rc.value.codeHash] = w

  # Handle mothballed pivots for swapping in (see `pivotMothball()`)
  if topLevel:
    env.savedFullPivotOk = env.pivotCompleteOk()
    when extraTraceMessages:
      trace logTxt "recovered top level record",
        pivot=env.stateHeader.blockNumber.toStr,
        savedFullPivotOk=env.savedFullPivotOk,
        processed=env.fetchAccounts.processed.fullPC3,
        nStoQ=env.storageQueueTotal()
  else:
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
    beaconHeader = ctx.pool.pass.beaconHeader
  var
    pivotHeader: BlockHeader

  block:
    let rc = ctx.pool.pass.pivotTable.lastValue
    if rc.isOk:
      pivotHeader = rc.value.stateHeader

  # Check whether the pivot needs to be updated
  if pivotHeader.blockNumber+pivotBlockDistanceMin <= beaconHeader.blockNumber:
    # If the entry before the previous entry is unused, then run a pool mode
    # based session (which should enable a pivot table purge).
    block:
      let rc = ctx.pool.pass.pivotTable.beforeLast
      if rc.isOk and rc.value.data.fetchAccounts.processed.isEmpty:
        ctx.poolMode = true

    when extraTraceMessages:
      trace logTxt "new pivot from beacon chain", peer=buddy.peer,
        pivot=pivotHeader.blockNumber.toStr,
        beacon=beaconHeader.blockNumber.toStr, poolMode=ctx.poolMode

    discard ctx.pool.pass.pivotTable.lruAppend(
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
    if ctx.pool.pass.beaconHeader.blockNumber < h.blockNumber:
      # when extraTraceMessages:
      #   trace logTxt "external beacon info update", header=h.blockNumber.toStr
      ctx.pool.pass.beaconHeader = h

# ------------------------------------------------------------------------------
# Public function, debugging
# ------------------------------------------------------------------------------

import
  ../../db/[hexary_desc, hexary_inspect, hexary_nearby, hexary_paths,
            snapdb_storage_slots]

const
  pivotVerifyExtraBlurb = false # or true
  inspectSuspendAfter = 10_000
  inspectExtraNap = 100.milliseconds

proc pivotVerifyComplete*(
    env: SnapPivotRef;              # Current pivot environment
    ctx: SnapCtxRef;                # Some global context
    inspectAccountsTrie = false;    # Check for dangling links
    walkAccountsDB = true;          # Walk accounts db
    inspectSlotsTries = true;       # Check dangling links (if `walkAccountsDB`)
    verifyContracts = true;         # Verify that code hashes are in database
      ): Future[bool]
      {.async,discardable.} =
  ## Check the database whether the pivot is complete -- not advidsed on a
  ## production system as the process takes a lot of ressources.
  let
    rootKey = env.stateHeader.stateRoot.to(NodeKey)
    accFn = ctx.pool.snapDb.getAccountFn
    ctraFn = ctx.pool.snapDb.getContractsFn

  # Verify consistency of accounts trie database. This should not be needed
  # if `walkAccountsDB` is set. In case that there is a dangling link that would
  # have been detected by `hexaryInspectTrie()`, the `hexaryNearbyRight()`
  # function should fail at that point as well.
  if inspectAccountsTrie:
    var
      stats = accFn.hexaryInspectTrie(rootKey,
        suspendAfter=inspectSuspendAfter,
        maxDangling=1)
      nVisited = stats.count
      nRetryCount = 0
    while stats.dangling.len == 0 and not stats.resumeCtx.isNil:
      when pivotVerifyExtraBlurb:
        trace logTxt "accounts db inspect ..", nVisited, nRetryCount
      await sleepAsync inspectExtraNap
      nRetryCount.inc
      stats = accFn.hexaryInspectTrie(rootKey,
        resumeCtx=stats.resumeCtx,
        suspendAfter=inspectSuspendAfter,
        maxDangling=1)
      nVisited += stats.count
      # End while

    if stats.dangling.len != 0:
      error logTxt "accounts trie has danglig links", nVisited, nRetryCount
      return false
    trace logTxt "accounts trie ok", nVisited, nRetryCount
    # End `if inspectAccountsTrie`

  # Visit accounts and make sense of storage slots
  if walkAccountsDB:
    var
      nAccounts = 0
      nStorages = 0
      nContracts = 0
      nRetryTotal = 0
      nodeTag = low(NodeTag)
    while true:
      if (nAccounts mod inspectSuspendAfter) == 0 and 0 < nAccounts:
        when pivotVerifyExtraBlurb:
          trace logTxt "accounts db walk ..",
            nAccounts, nStorages, nContracts, nRetryTotal,
            inspectSlotsTries, verifyContracts
        await sleepAsync inspectExtraNap

      # Find next account key => `nodeTag`
      let rc = nodeTag.hexaryPath(rootKey,accFn).hexaryNearbyRight(accFn)
      if rc.isErr:
        if rc.error == NearbyBeyondRange:
          break # No more accounts
        error logTxt "accounts db problem", nodeTag,
          nAccounts, nStorages, nContracts, nRetryTotal,
          inspectSlotsTries, verifyContracts, error=rc.error
        return false
      nodeTag = rc.value.getPartialPath.convertTo(NodeKey).to(NodeTag)
      nAccounts.inc

      # Decode accounts data
      var accData: Account
      try:
        accData = rc.value.leafData.decode(Account)
      except RlpError as e:
        error logTxt "account data problem", nodeTag,
          nAccounts, nStorages, nContracts, nRetryTotal,
          inspectSlotsTries, verifyContracts, name=($e.name), msg=(e.msg)
        return false

      # Check for storage slots for this account
      if accData.storageRoot != EMPTY_ROOT_HASH:
        nStorages.inc
        if inspectSlotsTries:
          let
            slotFn = ctx.pool.snapDb.getStorageSlotsFn(nodeTag.to(NodeKey))
            stoKey = accData.storageRoot.to(NodeKey)
          var
            stats = slotFn.hexaryInspectTrie(stoKey,
              suspendAfter=inspectSuspendAfter,
              maxDangling=1)
            nVisited = stats.count
            nRetryCount = 0
          while stats.dangling.len == 0 and not stats.resumeCtx.isNil:
            when pivotVerifyExtraBlurb:
              trace logTxt "storage slots inspect ..", nodeTag,
                nAccounts, nStorages, nContracts, nRetryTotal,
                inspectSlotsTries, verifyContracts, nVisited, nRetryCount
            await sleepAsync inspectExtraNap
            nRetryCount.inc
            nRetryTotal.inc
            stats = accFn.hexaryInspectTrie(stoKey,
              resumeCtx=stats.resumeCtx,
              suspendAfter=inspectSuspendAfter,
              maxDangling=1)
            nVisited += stats.count

          if stats.dangling.len != 0:
            error logTxt "storage slots trie has dangling link", nodeTag,
              nAccounts, nStorages, nContracts, nRetryTotal,
              inspectSlotsTries, nVisited, nRetryCount
            return false
          if nVisited == 0:
            error logTxt "storage slots trie is empty", nodeTag,
              nAccounts, nStorages, nContracts, nRetryTotal,
              inspectSlotsTries, verifyContracts, nVisited, nRetryCount
            return false

      # Check for contract codes for this account
      if accData.codeHash != EMPTY_CODE_HASH:
        nContracts.inc
        if verifyContracts:
          let codeKey = accData.codeHash.to(NodeKey)
          if codeKey.to(Blob).ctraFn.len == 0:
            error logTxt "Contract code missing", nodeTag,
              codeKey=codeKey.to(NodeTag),
              nAccounts, nStorages, nContracts, nRetryTotal,
              inspectSlotsTries, verifyContracts
            return false

      # Set up next node key for looping
      if nodeTag == high(NodeTag):
        break
      nodeTag = nodeTag + 1.u256
      # End while

    trace logTxt "accounts db walk ok",
      nAccounts, nStorages, nContracts, nRetryTotal, inspectSlotsTries
    # End `if walkAccountsDB`

  return true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
