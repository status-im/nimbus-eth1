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
  if not ctx.pool.mptAsm.clear info:
    return SnapIdle
  SnapReady

proc resumeNext(ctx: SnapCtxRef; info: static[string]): SyncState =
  ## State transition handler
  if ctx.readyForMptAssembly():
    return SnapMkTrie
  SnapReady

func readyNext(ctx: SnapCtxRef; info: static[string]): SyncState =
  ## State transition handler
  if ctx.hdrCache.latestConsHeadNumber() != 0:
    return SnapDownload
  SnapReady

func downloadNext(ctx: SnapCtxRef; info: static[string]): SyncState =
  ## State transition handler
  if ctx.readyForMptAssembly():
    ctx.poolMode = true                             # sync peers
    return SnapDownloadFinish
  SnapDownload

proc downloadFinishNext(ctx: SnapCtxRef; info: static[string]): SyncState =
  ## State transition handler
  if ctx.poolMode:                                  # wait for peers to sync
    return SnapDownloadFinish
  SnapMkTrie

func mkTrieNext(ctx: SnapCtxRef; info: static[string]): SyncState =
  ## State transition handler
  SnapAnalyse

func analyseNext(ctx: SnapCtxRef; info: static[string]): SyncState =
  ## State transition handler
  SnapHealing

func healingNext(ctx: SnapCtxRef; info: static[string]): SyncState =
  ## State transition handler
  # TBD ...
  SnapHealing

# ------------------------------------------------------------------------------
# Public FSA related functions
# ------------------------------------------------------------------------------

proc updateSyncReset*(ctx: SnapCtxRef) =
  ## Reset syncer state machine
  ctx.pool.syncState = SnapIdle

proc updateSyncResume*(ctx: SnapCtxRef) =
  ## Set explicit `resume` syncer state
  ctx.pool.syncState = SnapResume

proc updateSyncHealing*(ctx: SnapCtxRef) =
  ## Set explicit `healinh` syncer state
  ctx.pool.syncState = SnapHealing


proc updateSyncState*(ctx: SnapCtxRef; info: static[string]) =
  ## Update internal state when needed
  ##
  # State machine
  # ::
  #       initialise
  #        |      |
  #        v      v
  #    resume   idle
  #      | |      |
  #      | |      v
  #      | `--> ready
  #      |        |
  #      |        v
  #      |     download <--.
  #      |        |        |
  #      |        v        |
  #      |  downloadFinish |
  #      |        |        |
  #      |        v        |
  #      `----> mkTrie     |
  #               |        |
  #               v        |
  #      `     analyse ----'
  #               |
  #               v
  #            healing
  #               |
  #               v
  #              TBD ..
  #
  let newState =
    case ctx.pool.syncState:
    of SnapIdle:
      ctx.idleNext info
    of SnapResume:
      ctx.resumeNext info
    of SnapReady:
      ctx.readyNext info
    of SnapDownload:
      ctx.downloadNext info
    of SnapDownloadFinish:
      ctx.downloadFinishNext info
    of SnapMkTrie:
      ctx.mkTrieNext info
    of SnapAnalyse:
      ctx.analyseNext info
    of SnapHealing:
      ctx.healingNext info
  if ctx.pool.syncState == newState:
    return

  let
    prevState = ctx.pool.syncState
    sdb {.used.} = ctx.pool.stateDB                 # logging only

  ctx.pool.syncState = newState
  case newState:
  of SnapDownload, SnapDownloadFinish, SnapMkTrie,SnapAnalyse,  SnapHealing:
    chronicles.info info & ": State changed", prevState, newState,
      top=sdb.top, pivot=sdb.pivot.bnStr, nSyncPeers=ctx.nSyncPeers()
  of SnapIdle, SnapResume, SnapReady:
    debug "State changed", prevState, newState

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
          syncState=buddy.syncState, nSyncPeers=ctx.nSyncPeers()
      else:
        break body                                  # done, nothing to do

    let
      hdr = ctx.hdrCache.latestConsHead()
      blockNumber {.inject.} = BlockNumber(hdr.number)
    if blockNumber == 0:
      break body                                    # no FCU request yet

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
