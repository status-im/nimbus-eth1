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
  ./download/[account, bals, code, header, storage],
  ./[helpers, cache_db, worker_desc]

logScope:
  topics = "snap sync"

export
  account, header

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

# ------------------------------------------------------------------------------
# Public function(s)
# ------------------------------------------------------------------------------

proc downloadInit*(
    ctx: SnapCtxRef;
    info: static[string];
      ): Opt[void] =
  if not ctx.accUnproc.synced():
    # Update state number that can be advanced to
    ctx.pool.forwardNum = ctx.getLastBalNum()       # can forward to that state

    let adb = ctx.pool.cacheDB
    if ?adb.hasAccMissingIntv(info):                # have an account state?
      let accState = ?adb.getAccMissingIntv(info)
      ctx.accUnproc.unprocessed = accState.ranges   # copy reference (!)
      ctx.pool.pivotNum = accState.number           # set pivot
      debug info & ": Continue downloading", pivotNum=ctx.pool.pivotNum,
        forwardNum=ctx.pool.forwardNum
    else:
      let
        number = ?adb.lastHeaderNumber(info)
        accRng = ItemKeyRangeSet.init ItemKeyRangeMax
      ?adb.putAccMissingIntv(number, accRng, info)  # new state
      ctx.accUnproc.init ItemKeyRangeMax
      ctx.pool.pivotNum = number                    # set pivot
      debug info & ": Start downloading", pivotNum=ctx.pool.pivotNum,
        forwardNum=ctx.pool.forwardNum

    ctx.accountDownloadMetricsUpdate()
    ctx.accUnproc.synced = true
  ok()

proc downloadCommit*(
    ctx: SnapCtxRef;
    info: static[string];
      ): Result[void,ErrorType] =
  ## Finish downloading.
  ##
  # This directive should come after storing `accountDownloadCommit()`
  # updates. It will update the tables and delete partial MPTs.
  ?ctx.storageDownloadCommit(info)
  ?ctx.codeDownloadCommit(info)

  ?ctx.accountDownloadCommit(info)

  ok()

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
    var doEntity = toMask[int](0..2)
    while buddy.ctrl.running and doEntity != 0:

      if doEntity.testBit(0):
        buddy.accountDownload(stateRoot, number, info).isOkOr:
          if error != ECompleted:
            bodyRc = typeof(bodyRc).err(error)
            break
          doEntity.clearBit(0)                      # done with accounts
        doEntity.setBit(1)                          # re-activate storage & code
        doEntity.setBit(2)

      if doEntity.testBit(1):
        if buddy.ctrl.stopped:
          break
        buddy.storageDownload(stateRoot, number, info).isOkOr:
          if error != ECompleted:
            bodyRc = typeof(bodyRc).err(error)
            break
          doEntity.clearBit(1)                      # done with storage so far

      if doEntity.testBit(2):
        if buddy.ctrl.stopped:
          break
        buddy.codeDownload(stateRoot, number, info).isOkOr:
          if error != ECompleted:
            bodyRc = typeof(bodyRc).err(error)
            break
          doEntity.clearBit(2)                      # done with code so far
      # End `while ..`

    let data {.used.} = ctx.downloadReady(info).valueOr:
      trace info & ": Error reading cache DB", peer,
        syncState=($buddy.syncState), nSyncPeers=ctx.nSyncPeers()
      break body

    debug info & ": Downloaded data", peer, accountsDone=data.accDone,
      storageDone=data.stoDone, codeDone=data.codeDone,
      syncState=($buddy.syncState), nSyncPeers=ctx.nSyncPeers()
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

    trace info & ": Imported BALs", pivotNum=ctx.pool.pivotNum,
      forwardNum=ctx.pool.forwardNum, nBALs=rc.value

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
