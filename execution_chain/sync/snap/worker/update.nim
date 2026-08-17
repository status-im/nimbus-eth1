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
  ./[worker_const, worker_desc]

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Private FSA transition functions
# ------------------------------------------------------------------------------

proc idleNext(ctx: SnapCtxRef; info: static[string]): SnapState =
  ## State transition handler
  SnapIdle

proc readyNext(ctx: SnapCtxRef; info: static[string]): SnapState =
  ## State transition handler
  SnapReady

proc resumeNext(ctx: SnapCtxRef; info: static[string]): SnapState =
  ## State transition handler
  SnapResume

func downloadNext(ctx: SnapCtxRef; info: static[string]): SnapState =
  ## State transition handler
  SnapDownload                                      # otherwise stay

proc downloadFinishNext(ctx: SnapCtxRef; info: static[string]): SnapState =
  ## State transition handler
  if ctx.poolMode:                                  # wait for peers to sync
    return SnapDownloadFinish
  SnapStop

# TBD ..

func stopNext(ctx: SnapCtxRef; info: static[string]): SnapState =
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
  #         v          v
  #       [...]      [...]
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
    of SnapStop:
      ctx.stopNext info

  if ctx.pool.syncState == newState:
    return newState

  let prevState = ctx.pool.syncState
  ctx.pool.syncState = newState
  case newState:
  of SnapDownload, SnapDownloadFinish:
    chronicles.info info & ": State changed", prevState, newState,
      nSyncPeers=ctx.nSyncPeers()
  of SnapStop:
    chronicles.info info & ": State changed", prevState, newState,
      nSyncPeers=ctx.nSyncPeers()
  of SnapResume:
    debug info & ": State changed", prevState, newState
  of SnapReady, SnapIdle:
    debug info & ": State changed", prevState, newState

  newState

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
