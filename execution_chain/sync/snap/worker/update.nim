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
  ./[download, mpt, session, worker_const, worker_desc]

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Private FSA transition functions
# ------------------------------------------------------------------------------

proc idleNext(ctx: SnapCtxRef; info: static[string]): SyncState =
  ## State transition handler
  if not ctx.pool.mptAsm.clear info:
    return SnapIdle
  SnapDownload

proc resumeNext(ctx: SnapCtxRef; info: static[string]): SyncState =
  ## State transition handler
  # Recover session (if any)
  if ctx.sessionResume(info):
    debug info & ": resuming download session"
  SnapDownload

proc downloadNext(ctx: SnapCtxRef; info: static[string]): SyncState =
  ## State transition handler
  let sdb = ctx.pool.stateDB
  sdb.pivot().isErrOr:
    # Check whether the `pivot` data have been fully downloaded
    if value.totalAccountRange().isErr():           # err => all accounts done
      if value.len == 0:                            # no slots/code todo
        return SnapMkTrie
    # Check whether total coverage is sufficient
    # TBD ..
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
  #     idle   resume
  #      |      /
  #      |     /
  #      |    /
  #      v   v
  #     download <--.
  #      |          |
  #      v          |
  #     mkTrie -----'
  #      |
  #      v
  #     healing
  #      |
  #      v
  #     TBD ..
  #
  let newState =
    case ctx.pool.syncState:
    of SnapIdle:
      ctx.idleNext info
    of SnapResume:
      ctx.resumeNext info
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
    info "State changed", prevState, newState, top=sdb.top.bnStr,
      pivot=sdb.pivot.bnStr, nSyncPeers=ctx.nSyncPeers()
  else:
    debug "State changed", prevState, newState, top=sdb.top.bnStr,
      pivot=sdb.pivot.bnStr, nSyncPeers=ctx.nSyncPeers()

# ------------------------------------------------------------------------------
# Other public functions
# ------------------------------------------------------------------------------

template updateTarget*(
    buddy: SnapPeerRef;
    info: static[string];
      ) =
  ## Async/template
  ##
  block body:
    # Check whether explicit target setup is configured
    if buddy.ctx.pool.target.isSome():
      let
        peer {.inject,used.} = $buddy.peer          # logging only
        ctx = buddy.ctx

      # Single target block hash
      let hash = ctx.pool.target.value.blockHash
      if hash != BlockHash(zeroHash32):
        let rc = buddy.headerStateRegister(hash, info)
        if rc.isErr and rc.error:                   # real error
          trace info & ": failed fetching pivot hash", peer, hash=hash.toStr
        elif 0 < ctx.pool.target.value.updateFile.len:
          var target = ctx.pool.target.value
          target.blockHash = BlockHash(zeroHash32)
          ctx.pool.target = Opt.some(target)
        else:
          ctx.pool.target = Opt.none(SnapTarget)    # No more target entries
          break body                                # noting more to do here

      # Check whether a file target setup is configured
      if 0 < ctx.pool.target.value.updateFile.len:
        discard buddy.headerStateLoad(ctx.pool.target.value.updateFile, info)

  discard # visual alignment

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
