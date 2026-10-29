# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/bitops,
  pkg/[chronicles, chronos, stew/interval_set],
  ./download/[account, bals, code, delete_account, header, storage],
  ./[helpers, cache_db, worker_desc]

logScope:
  topics = "snap sync"

export
  account, header, storage

type
  DownloadInfo = tuple
    accDone: bool
    stoDone: bool
    codeDone: bool

# ------------------------------------------------------------------------------
# Private function
# ------------------------------------------------------------------------------

proc getStateRoot(
    buddy: SnapPeerRef;
    info: static[string];
      ): Opt[(StateRoot,BlockNumber)] =
  let
    adb = buddy.ctx.pool.cacheDB
    accState = ?adb.getAccMissingIntv(info)
    stateHdr = ?adb.getHeader(accState.number, info)
  ok((StateRoot stateHdr.stateRoot, accState.number))

proc getLastBalNum(ctx: SnapCtxRef): BlockNumber =
  ## Return `BlockNumber(0)` unless found. No error logging here.
  let maybe = ctx.pool.cacheDB.lastBalNumber().valueOr:
    return BlockNumber(0)
  if maybe.isSome():
    return maybe.unsafeGet()
  # BlockNumber(0)

proc downloadReady(
    ctx: SnapCtxRef;
    info: static[string];
      ): Opt[DownloadInfo] =
  let adb = ctx.pool.cacheDB
  var w: DownloadInfo
  w.accDone = ctx.accUnproc.synced() and ctx.accUnproc.chunks() == 0
  w.stoDone = not ?adb.hasStoMissingIntv(info) and not ?adb.hasStoLock(info)
  w.codeDone = not ?adb.hasMissingBlob(info) and not ?adb.hasCodeLock(info)
  ok(w)

proc setFirstPivotFromFinNumber(
    ctx: SnapCtxRef;
    info: static[string];
      ): Opt[BlockNumber] =
  ## Opportunistically fetch the pivot number from an ongoing first sync
  ## and use it to set the pivot.
  if ctx.pool.pivotNum == 0 and                     # => forwardNum == 0
     not ctx.pool.headersSynced:
    ctx.hdrCache.finHeader().isErrOr:
      if ctx.chain.com.isAmsterdamOrLater(value.timestamp):
        # Store header. So the pivot has a target on the DB. Note that this
        # same header might also be stored independently by the header
        # downloader.
        ctx.pool.cacheDB.putHeader(value, info).isErrOr:
          debug info & ": Opportunistically accept pivot", pivot=value.number
          ctx.pool.balSupported = true              # so state download ok, now
          return Opt.some(value.number)
  Opt.none(BlockNumber)

proc startDownloading(
    ctx: SnapCtxRef;
    pivotNum: Opt[BlockNumber];
    info: static[string];
      ): Opt[void] =
  let
    adb = ctx.pool.cacheDB
    number = if pivotNum.isSome(): pivotNum.unsafeGet()
             else: ?adb.lastHeaderNumber(info)      # => err() unless headers
    accRng = ItemKeyRangeSet.init ItemKeyRangeMax
  ?adb.putAccMissingIntv(number, accRng, info)      # new state
  ctx.accUnproc.init ItemKeyRangeMax
  ctx.pool.pivotNum = number                        # set pivot
  if 0 < ctx.pool.pivotNum:
    debug info & ": Start downloading accounts",
      pivotNum=ctx.pool.pivotNum, forwardNum=ctx.pool.forwardNum
  ok()

proc verifyAmsterdamOrLater(
    ctx: SnapCtxRef;
    info: static[string];
      ): Opt[void] =
  if ctx.pool.balSupported:
    return ok()

  ctx.pool.cacheDB.lastHeader().isErrOr:
    if value.isSome():
      let lastHdr = value.unsafeGet()
      if ctx.chain.com.isAmsterdamOrLater(lastHdr.timestamp):
        ctx.pool.balSupported = true
        return ok()
      # Not logging until the first headers batch was downloaded
      if lastHdr.number == BlockNumber(0):
        return err()
    else:
      # Not logging until the first headers batch was downloaded
      return err()

  ctx.pool.lastNoBalSupport.logCtrl(noBalSupportLogWaitInterval):
    chronicles.info info & ": No BAL support yet (needs Amsterdam or later)"
  err()

# ------------------------------------------------------------------------------
# Public function(s)
# ------------------------------------------------------------------------------

proc downloadInit*(
    ctx: SnapCtxRef;
    info: static[string];
      ): Opt[void] =
  let firstPivot = ctx.setFirstPivotFromFinNumber(info)
  if not ctx.accUnproc.synced():
    ?ctx.verifyAmsterdamOrLater(info)

    # Update state number that can be advanced to
    ctx.pool.forwardNum = ctx.getLastBalNum()       # can forward to that state

    let adb = ctx.pool.cacheDB
    if ?adb.hasAccMissingIntv(info):                # have an account state?
      let accState = ?adb.getAccMissingIntv(info)
      ctx.accUnproc.unprocessed = accState.ranges   # copy reference (!)
      ctx.pool.pivotNum = accState.number           # set pivot
      if 0 < ctx.pool.pivotNum:                     # ready ok?
        debug info & ": Continue downloading accounts",
          pivotNum=ctx.pool.pivotNum, forwardNum=ctx.pool.forwardNum
    else:
      ?ctx.startDownloading(firstPivot, info)

    ctx.accUnproc.synced = true

  elif ctx.pool.pivotNum == 0:                      # delayed intialisation?
    ?ctx.startDownloading(firstPivot, info)

  ctx.accountDownloadMetricsUpdate()
  ctx.storageDownloadMetricsUpdate(info)
  ok()

template downloadCommit*(
    ctx: SnapCtxRef;
    info: static[string];
      ): auto =
  ## Async template
  ##
  ## Finish downloading.
  ##
  # This directive should come last after storing state data when all peers
  # are idle (i.e. synchronised.) It will update the tables and delete partial
  # MPTs.
  var bodyRc = Result[void,ErrorType].ok()
  block body:
    var timer = TimerDataRef(time: Moment.now())

    ctx.storageDownloadCommit(timer, info).isOkOr:
      bodyRc = typeof(bodyRc).err(error)
      break body

    ctx.codeDownloadCommit(timer, info).isOkOr:
      bodyRc = typeof(bodyRc).err(error)
      break body

    ctx.accountDownloadCommit(info).isOkOr:
      bodyRc = typeof(bodyRc).err(error)
      break body

    chronicles.info info & ": Ready for state update"
    # End `block body`

  bodyRc

template downloadState*(
    buddy: SnapPeerRef;
    info: static[string];
      ): auto =
  ## Async/template
  ##
  ## Fetch and stash account, storage, and code ranges for available state
  ## roots, the order of which is determined by the following criteria with
  ## decreaning priority
  ##
  ## * the state that has already the most accounts downloaded
  ## * the pivot state for this `peer`
  ## * other states with decreasing block number (i.e. most recent first)
  ##   + not older than the first two states (if any),
  ##   + and no more than `nWorkingStateRoots`
  ##
  var bodyRc = Result[void,ErrorType].ok()
  block body:
    let
      ctx = buddy.ctx

      (stateRoot, number {.inject.}) = buddy.getStateRoot(info).valueOr:
        trace info & ": Not ready yet for downloading", peer,
          syncState=($buddy.syncState), nSyncPeers=ctx.nSyncPeers()
        bodyRc = typeof(bodyRc).err(EGeneric)
        break body

      peer {.inject,used.} = $buddy.peer            # logging only
      root {.inject,used.} = stateRoot.toStr        # logging only

    # Run through different download entities as long as they are available.
    # Non-availability might also mean tat they are temporarily blocked and
    # might be available later.
    #
    # bitmask doEntity:
    # * bit 0: do accounts
    # * bit 1: do storages
    # * bit 2: do contract codes
    #
    var
      didSomething = false                          # logging only
      doEntity = toMask[int](0..2)
    while buddy.ctrl.running and doEntity != 0:

      if doEntity.testBit(0):
        let rc = buddy.accountDownload(stateRoot, number, info)
        if rc.isOk:
          didSomething = true                       # logging only
          doEntity.setBit(1)                        # re-activate storage & code
          doEntity.setBit(2)
        elif rc.error == ECompleted:
          doEntity.clearBit(0)                      # done with accounts
        else:
          bodyRc = typeof(bodyRc).err(rc.error)
          break

      if doEntity.testBit(1):
        if buddy.ctrl.stopped:
          break
        let rc = buddy.storageDownload(stateRoot, number, info)
        if rc.isOk:
          didSomething = true                       # logging only
        elif rc.error == ECompleted:
          doEntity.clearBit(1)                      # done with storage so far
        else:
          bodyRc = typeof(bodyRc).err(rc.error)
          break

      if doEntity.testBit(2):
        if buddy.ctrl.stopped:
          break
        let rc = buddy.codeDownload(stateRoot, number, info)
        if rc.isOk:
          didSomething = true                       # logging only
        elif rc.error == ECompleted:
          doEntity.clearBit(2)                      # done with code so far
        else:
          bodyRc = typeof(bodyRc).err(rc.error)
          break
      # End `while ..`

    let data {.used.} = ctx.downloadReady(info).valueOr:
      trace info & ": Error reading cache DB", peer,
        syncState=($buddy.syncState), nSyncPeers=ctx.nSyncPeers()
      break body

    if didSomething:
      debug info & ": Downloaded data", peer, accountsDone=data.accDone,
        storageDone=data.stoDone, codeDone=data.codeDone,
        syncState=($buddy.syncState), nSyncPeers=ctx.nSyncPeers()
      discard

    # End `block body`

  bodyRc                                            # return value

template downloadBals*(
    buddy: SnapPeerRef;
    info: static[string];
      ): auto =
  var bodyRc = Result[void,ErrorType].err(EGeneric)
  block body:
    let
      ctx = buddy.ctx
      peer {.inject,used.} = $buddy.peer            # logging only

    if not ctx.pool.balsLocked.isNil:               # already downloading?
      bodyRc = typeof(bodyRc).err(ELockError)
      break body

    ctx.pool.balsLocked = buddy                     # unique access
    let rc = buddy.balsDownloadAppend(info)
    ctx.pool.balsLocked = SnapPeerRef(nil)

    if rc.isErr:
      bodyRc = typeof(bodyRc).err(rc.error)
      break body

    ctx.pool.forwardNum = ctx.getLastBalNum()
    bodyRc = typeof(bodyRc).ok()

    chronicles.info info & ": Imported BALs", pivotNum=ctx.pool.pivotNum,
      forwardNum=ctx.pool.forwardNum, nBALs=rc.value

  bodyRc

template downloadResume*(
    ctx: SnapCtxRef;
    info: static[string];
      ): auto =
  ## Async template
  ##
  ## Attempt to resume an interrupted download session
  ##
  var bodyRc = Opt[void].err()
  block body:
    let adb = ctx.pool.cacheDB

    # Cannot have lock entries
    for _ in adb.walkStoLock:
      break body                                    # failed immediately
    for _ in adb.walkCodeLock:
      break body                                    # failed immediately

    # Clean up as best as possible
    var
      accPaths: seq[Hash32]
      timer = TimerDataRef(time: Moment.now())

    # Collect paths for partial storage sub-MPTs and contract codes
    for w in adb.walkStoMissingIntv:
      if 0 < w.error.len:
        error info & ": Error walking missing storage list", `error`=w.error
        break body                                  # failed
      accPaths.add w.accPath
      timer.yieldThread()
    for key in adb.walkMissingBlob:
      accPaths.add key

    # Delete all accounts for partial sub-MPTs and contract codes.
    for accPath in accPaths:
      ctx.deleteAccount(accPath, info).isOkOr:
        break body                                  # failed

    bodyRc = typeof(bodyRc).ok()
    # End `block body`

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
