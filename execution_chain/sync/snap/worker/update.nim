# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/chronicles,
  ./[mpt, worker_const, worker_desc]

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc allDownloaded(ctx: SnapCtxRef; info: static[string]): Opt[void] =
  let adb = ctx.pool.cacheDB
  if not ?adb.hasAccMissingIntv(info) and           # accounts not ready yet?
     not ?adb.hasStoMissingIntv(info) and           # storage left (or error)?
     not ?adb.hasMissingBlob(info):                 # codes left (or error)?
    return ok()
  err()

# ------------------------------------------------------------------------------
# Private FSA transition functions
# ------------------------------------------------------------------------------

proc idleNext(ctx: SnapCtxRef; info: static[string]): SnapState =
  ## State transition handler
  if ctx.pool.contPrevSession:
    return SnapResume
  SnapClear

proc resumeNext(ctx: SnapCtxRef; info: static[string]): SnapState =
  ## State transition handler
  let haveData = ctx.pool.cacheDB.hasAccMissingIntv(info).valueOr:
    return SnapStop                                 # DB problem, failure

  if haveData and ctx.accUnproc.synced():
    info info & ": Resuming previous session"
    return SnapBalsFetch

  info info & ": No previous session available"
  SnapClear

proc clearNext(ctx: SnapCtxRef; info: static[string]): SnapState =
  ## State transition handler
  let haveData = ctx.pool.cacheDB.hasAccMissingIntv(info).valueOr:
    return SnapStop                                 # DB problem, failure
  if haveData:
    return SnapClear
  SnapReady

proc readyNext(ctx: SnapCtxRef; info: static[string]): SnapState =
  ## State transition handler
  # Wait until initial headers are downloaded and available. Then check
  # whether snap syncer book keeping has been set up.
  # is inialised
  if not ctx.pool.headersSynced:
    return SnapReady
  if not ctx.accUnproc.synced():
    return SnapReady
  SnapDownload

# -------------------------

proc downloadNext(ctx: SnapCtxRef, info: static[string]): SnapState =
  ## State transition handler
  # Check whether one should forward the downloaded partial state
  let consHeadNum = ctx.hdrCache.latestConsHeadNumber()
  if ctx.pool.pivotNum + consHeadSupportWindowSize < consHeadNum:
    ctx.poolMode = true
    return SnapDownloadFinish                       # => sync peers
  ctx.allDownloaded(info).isErrOr:                  # download is complete?
    ctx.poolMode = true
    return SnapDownloadFinish                       # => sync peers
  SnapDownload                                      # keep downloading

proc downloadFinishNext(ctx: SnapCtxRef, info: static[string]): SnapState =
  ## State transition handler
  if ctx.poolMode:                                  # wait for peers to sync
    return SnapDownloadFinish
  ctx.allDownloaded(info).isErrOr:                  # download is complete?
    ctx.poolMode = true
  SnapBalsFetch

proc balsFetchNext(ctx: SnapCtxRef, info: static[string]): SnapState =
  ## State transition handler
  if ctx.pool.pivotNum < ctx.pool.forwardNum:       # can bring forward state?
    ctx.poolMode = true
    return SnapBalsFetchFinish
  SnapBalsFetch

proc balsFetchFinishNext(ctx: SnapCtxRef, info: static[string]): SnapState =
  ## State transition handler
  if ctx.poolMode:                                  # wait for peers to sync
    return SnapBalsFetchFinish
  SnapStateForward

proc stateForwardNext(ctx: SnapCtxRef, info: static[string]): SnapState =
  ## State transition handler
  if ctx.pool.pivotNum < ctx.pool.forwardNum:       # must bring forward state
    return SnapStateForward
  if true:                                          # FIXME, must change
    return SnapDownload
  SnapStop                                          # FIXME, must change

# TBD ..

func stopNext(ctx: SnapCtxRef, info: static[string]): SnapState =
  SnapStop

# ------------------------------------------------------------------------------
# Public FSA related functions
# ------------------------------------------------------------------------------

proc updateSnapState*(ctx: SnapCtxRef; info: static[string]): SnapState =
  ## Update internal state when needed
  ##
  #
  # State machine
  # ::
  #                         idle ---------.
  #                           |           |
  #                           v           v
  #                        resume ----> clear
  #                           |           |
  #                           v           v
  #                .----> balsFetch     ready
  #                |          |           |
  #                |          v           |
  #                |    balsFetchFinish   |
  #                |          |           |
  #                |          v           |
  #                |     stateForward     |
  #                |          |           |
  #                |          v           |
  #                |       download <-----'
  #                |          |
  #                |          v
  #                `--- downloadFinish
  #                           |
  #                           v
  #                         [...]
  #                           |
  #                           v
  #                         stop
  #
  let newState =
    case ctx.pool.syncState:
    of SnapIdle:
      ctx.idleNext info
    of SnapClear:
      ctx.clearNext info
    of SnapResume:
      ctx.resumeNext info
    of SnapReady:
      ctx.readyNext info
    of SnapDownload:
      ctx.downloadNext info
    of SnapDownloadFinish:
      ctx.downloadFinishNext info
    of SnapBalsFetch:
      ctx.balsFetchNext info
    of SnapBalsFetchFinish:
      ctx.balsFetchFinishNext info
    of SnapStateForward:
      ctx.stateForwardNext info

    # [..]

    of SnapStop:
      ctx.stopNext info

  if ctx.pool.syncState == newState:
    return newState

  let prevState = ctx.pool.syncState
  ctx.pool.syncState = newState

  case newState:
  of SnapReady, SnapDownload, SnapDownloadFinish:
    chronicles.info info & ": State changed", prevState, newState,
      pivot=ctx.pool.pivotNum, nSyncPeers=ctx.nSyncPeers()
  of SnapBalsFetch, SnapBalsFetchFinish, SnapStateForward:
    chronicles.info info & ": State changed", prevState, newState,
      pivot=ctx.pool.pivotNum, forward=ctx.pool.forwardNum,
      nSyncPeers=ctx.nSyncPeers()
  of SnapIdle, SnapResume, SnapClear, SnapStop:
    chronicles.info info & ": State changed", prevState, newState,
      nSyncPeers=ctx.nSyncPeers()

  newState

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
