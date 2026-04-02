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
  ./download/header,
  ./[mpt, session, worker_const, worker_desc]

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func pivotIsComplete(ctx: SnapCtxRef): bool =
  ## State transition helper
  ctx.pool.stateDB.pivot().isErrOr:
    if value.isComplete():
      return true
  # false

func pivotIsSufficient(ctx: SnapCtxRef): bool =
  ## State transition helper
  let sdb = ctx.pool.stateDB
  # Check acummulated coverage
  if sdb.accountsCoverage() < accuAccountsCovMin:
    return false                                    # not enough yet => fail
  # Check pivot state
  sdb.pivot().isErrOr:
    if accuPivotCovMin <= value.accountsCoverage(): # check pivot coverage
      return true                                   # enough => OK
  false

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
  # Recover session (if any)
  if ctx.sessionResume(info) and
     ctx.pivotIsComplete():
    return SnapMkTrie
  SnapReady

func readyNext(ctx: SnapCtxRef; info: static[string]): SyncState =
  ## State transition handler
  if ctx.pool.target.isSome() or
     ctx.hdrCache.latestConsHeadNumber() != 0:
    return SnapDownload
  SnapReady

func downloadNext(ctx: SnapCtxRef; info: static[string]): SyncState =
  ## State transition handler
  if ctx.pivotIsComplete() or
     ctx.pivotIsSufficient():
    return SnapMkTrie
  SnapDownload

func mkTrieNext(ctx: SnapCtxRef; info: static[string]): SyncState =
  ## State transition handler
  ctx.pool.stateDB.pivot.isErrOr:
    if value.getHealingReady():
      return SnapHealing
  SnapDownload

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
  #      `----> mkTrie ----'
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
    of SnapMkTrie:
      ctx.mkTrieNext info
    of SnapHealing:
      ctx.healingNext info
  if ctx.pool.syncState == newState:
    return

  let
    prevState = ctx.pool.syncState
    sdb {.used.} = ctx.pool.stateDB                 # logging only

  ctx.pool.syncState = newState
  case newState:
  of SnapDownload, SnapMkTrie, SnapHealing:
    chronicles.info info & ": State changed", prevState, newState,
      top=sdb.top.bnStr, pivot=sdb.pivot.bnStr, nSyncPeers=ctx.nSyncPeers()
  of SnapIdle, SnapResume, SnapReady:
    debug "State changed", prevState, newState

# ------------------------------------------------------------------------------
# Other public functions
# ------------------------------------------------------------------------------

template updateTarget*(buddy: SnapPeerRef, info: static[string]) =
  ## Async/template
  ##
  ## Check for manually set sync target (e.g. set by a command line option)
  ##
  block body:
    # Check whether explicit target setup is configured
    let
      ctx = buddy.ctx
      hash = ctx.pool.target.valueOr:
        break body                                  # nothing to do

    trace info & ": assigning manual target state", peer=buddy.peer,
      hash=hash.toStr, nSyncPeers=ctx.nSyncPeers()

    buddy.headerStateRegister(hash, info).isErrOr:
      ctx.pool.target = Opt.none(BlockHash)         # fetch only once
    # End `block body`

  discard                                           # visual alignment

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
    if buddy.only.finRoot.isSome():
      break body                                    # done, nothing to do

    let
      ctx = buddy.ctx
      hdr = ctx.hdrCache.latestConsHead()
      blockNumber {.inject.} = BlockNumber(hdr.number)
    if blockNumber == 0:
      break body                                    # no FCU request yet

    let hash = BlockHash(hdr.computeBlockHash())
    ctx.pool.stateDB.get(hash).isErrOr:
      trace info & ": using fin root from registry", peer=buddy.peer,
        blockHash=hash.toStr, blockNumber, nSyncPeers=ctx.nSyncPeers()
      buddy.only.finRoot = Opt.some(value.stateRoot)
      break body                                    # already registered

    trace info & ": assigning FCU hash from CL", peer=buddy.peer,
      hash=hash.toStr, blockNumber, nSyncPeers=ctx.nSyncPeers()

    # Store root -> block data mapping
    let root = StateRoot(hdr.stateRoot)
    ctx.pool.mptAsm.putBlockData(root, hash, blockNumber).isOkOr:
      trace info & ": Cannot store state root map", peer=buddy.peer,
        stateRoot=root.toStr, blockHash=hash.toStr, blockNumber
      break body                                    # done, storage error

    discard ctx.pool.stateDB.register(root, hash, blockNumber, info)
    buddy.only.finRoot = Opt.some(root)
    # End `block body`

  discard                                           # visual alignment

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
