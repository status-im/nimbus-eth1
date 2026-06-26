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
  ./[helpers, mpt, session, state_db, worker_const, worker_desc]

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func readyForMptAssembly(ctx: SnapCtxRef): bool =
  ## State transition helper
  let sdb = ctx.pool.stateDB
  sdb.isComplete or
    accuAccountsCovMin < sdb.archivedCoverage() + sdb.accountsCoverage()

# ------------------------------------------------------------------------------
# Private FSA transition functions
# ------------------------------------------------------------------------------

proc idleNext(ctx: SnapCtxRef; info: static[string]): SyncState =
  ## State transition handler
  if ctx.pool.contPrevSession:
    chronicles.info info & ": Resuming previous session"
  elif not ctx.pool.mptAsm.clear(info):
    return SnapIdle                                 # disk full?, stay anyway
  SnapReady

func readyNext(ctx: SnapCtxRef; info: static[string]): SyncState =
  ## State transition handler
  # Wait for the beacon syncer to have completed the first header chain
  # download  which might be considerably more to do than any subsequent
  # updates.
  block stayReady:
    if ctx.pool.headersSynced:
      # So some headers have been downloaded
      if ctx.hdrCache.latestConsHeadNumber() != 0:
        break stayReady                             # all sort of working, now
      if ctx.pool.beaconTarget:
        # This is some artificial or test mode when the becon sync server has
        # a manual target set to download, to, first. For the same test resons,
        # the snap syncer will start with a head from the header chain cache
        # if there is no finalised CL header available.
        break stayReady
      # End `if headersSynced`
    return SnapReady
  if ctx.pool.contPrevSession:
    return SnapResume
  SnapDownload

proc resumeNext(ctx: SnapCtxRef; info: static[string]): SyncState =
  ## State transition handler
  # Continuing a a session is fully controlled by the daemon (no peers'
  # interaction.) So there is no need to sync via `poolMode`.
  ctx.getPivotTag(info).isErrOr:
    if PivotOnTrie <= value:
      return SnapAnalyse
  if ctx.readyForMptAssembly():
    return SnapMkTrie
  SnapDownload

func downloadNext(ctx: SnapCtxRef; info: static[string]): SyncState =
  ## State transition handler
  if ctx.readyForMptAssembly():
    ctx.poolMode = true                             # sync peers needed
    return SnapDownloadFinish
  SnapDownload                                      # otherwise stay

proc downloadFinishNext(ctx: SnapCtxRef; info: static[string]): SyncState =
  ## State transition handler
  if ctx.poolMode:                                  # wait for peers to sync
    return SnapDownloadFinish
  SnapMkTrie

proc mkTrieNext(ctx: SnapCtxRef; info: static[string]): SyncState =
  ## State transition handler
  if ctx.pool.pivot.isNone():                       # enter unless pivot is set
    return SnapMkTrie
  # Continuing a a session is fully controlled by the daemon (no peers'
  # interaction.) So there is no need to sync via `poolMode`.
  SnapAnalyse

proc analyseNext(ctx: SnapCtxRef; info: static[string]): SyncState =
  ## State transition handler
  ctx.getPivotTag(info).isErrOr:
    if PivotMptAnalysed <= value:
      return SnapStop                               # FIXME-- might change
  SnapAnalyse

# TBD ..

func stopNext(ctx: SnapCtxRef; info: static[string]): SyncState =
  SnapStop

# ------------------------------------------------------------------------------
# Public FSA related functions
# ------------------------------------------------------------------------------

proc updateSyncState*(ctx: SnapCtxRef; info: static[string]): SyncState =
  ## Update internal state when needed
  ##
  #
  # State machine
  # ::
  #                  idle
  #                    |
  #                    v
  #      resume <--- ready
  #         |          |
  #         |          v
  #         |      download
  #         |          |
  #         |          v
  #         |    downloadFinish
  #         |          |
  #         |          v
  #         +------> mkTrie
  #         |          |
  #         |          v
  #         `---->  analyse
  #                    |
  #                    v
  #                  [...]
  #                    |
  #                    v
  #                  stop
  #
  let newState =
    case ctx.pool.syncState:
    of SnapIdle:
      ctx.idleNext info
    of SnapReady:
      ctx.readyNext info
    of SnapResume:
      ctx.resumeNext info
    of SnapDownload:
      ctx.downloadNext info
    of SnapDownloadFinish:
      ctx.downloadFinishNext info
    of SnapMkTrie:
      ctx.mkTrieNext info
    of SnapAnalyse:
      ctx.analyseNext info
    of SnapStop:
      ctx.stopNext info

  if ctx.pool.syncState == newState:
    return newState

  let
    prevState = ctx.pool.syncState
    sdb {.used.} = ctx.pool.stateDB                 # logging only

  ctx.pool.syncState = newState
  case newState:
  of SnapDownload, SnapDownloadFinish, SnapMkTrie:
    chronicles.info info & ": State changed", prevState, newState,
      top=sdb.top, pivot=sdb.pivot.bnStr, nSyncPeers=ctx.nSyncPeers()
  of SnapAnalyse, SnapStop:
    chronicles.info info & ": State changed", prevState, newState,
      pivot=ctx.pool.pivot.toStr, nSyncPeers=ctx.nSyncPeers()
  of SnapIdle, SnapResume, SnapReady:
    debug "State changed", prevState, newState

  newState

# ------------------------------------------------------------------------------
# Other public functions
# ------------------------------------------------------------------------------

template updateFcuRoot*(buddy: SnapPeerRef, info: static[string]) =
  ## Async/template
  ##
  ## Register state record derived from the finalised header sent from the
  ## CL as FCU update and use it as peer target (or pivot.)
  ##
  ## Note that the best/latest header is not useful here as a substitute
  ## for the CL finalised hash. Reasons are
  ##
  ## * In most cases, the best/latest hash is the same as the FCU update
  ##
  ## * Otherwise it needs to be verified by a header back chain starting
  ##   from a CL header at some time as only the CL has authority. This
  ##   would be an extra efford not deemed worth while.
  ##
  block body:
    let
      ctx = buddy.ctx
      sdb = ctx.pool.stateDB
      peer {.inject,used.} = $buddy.peer            # logging only

    buddy.only.finRoot.isErrOr:                     # already set?
      # Check whether this state root still applies. If so, then
      # do nothing and return. Otherwise reset and find a new one.
      #
      # The underlying assumption is, that a `snap` peer serves a list of
      # states with consecutive, increasing block numbers ending up near or
      # at the latest block number of the FCU finalised hash.
      #
      let rc = sdb.get(value)
      if rc.isErr:
        buddy.only.finRoot = Opt.none(StateRoot)
      elif buddy.only.notAvailMax <= rc.value.blockNumber:
        buddy.only.finRoot = Opt.none(StateRoot)
        trace info & ":fin root too old, disbanding", peer,
          root=rc.value.rootStr, notAvailMax=buddy.only.notAvailMax,
          syncState=($buddy.syncState), nSyncPeers=ctx.nSyncPeers()
      else:
        break body                                  # done, nothing to do

    let
      hdr = ctx.hdrCache.latestConsHead()
      blockNumber {.inject.} = BlockNumber(hdr.number)
    if blockNumber == 0:                            # no FCU request yet
      # Check whether there has been a recent header download by the
      # beacon syncer. Typically, it will relay on the FCU update, but
      # for the initial phase there might be a manual sync target set.
      #
      # The latter is exploited for getting the snap syncer trying to fetch
      # a recent manually set header target related state from snap sync
      # peers. When doing this, success is only expected for test peers as
      # this state most certainly falls out of the supported 128 latest
      # states window.
      if ctx.pool.beaconTarget:                     # check for manual heder trg
        let
          adb = ctx.pool.mptAsm
          lastHeader = adb.lastHeader().valueOr:
            break body
          lastHash = adb.getBlockHash(lastHeader.number).valueOr:
            break body
          root = StateRoot lastHeader.stateRoot
        discard sdb.register(root, BlockHash lastHash, lastHeader.number, info)
        buddy.only.finRoot = Opt.some(root)
        # End `if beaconTarget`
      break body

    let
      hash = BlockHash(hdr.computeBlockHash())
      root = StateRoot(hdr.stateRoot)
    ctx.pool.stateDB.get(root).isErrOr:
      trace info & ": using fin root from registry", peer,
        blockHash=hash.toStr, blockNumber, nSyncPeers=ctx.nSyncPeers()
      buddy.only.finRoot = Opt.some(root)
      break body                                    # already registered

    trace info & ": assigning FCU hash from CL", peer,
      hash=hash.toStr, blockNumber, nSyncPeers=ctx.nSyncPeers()

    discard sdb.register(root, hash, blockNumber, info)
    buddy.only.finRoot = Opt.some(root)
    # End `block body`

  discard                                           # visual alignment

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
