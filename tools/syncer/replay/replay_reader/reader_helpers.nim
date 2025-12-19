# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Replay helpers

{.push raises:[].}

import
  std/strutils,
  pkg/[chronos, eth/common],
  ../../trace/trace_setup/setup_helpers as trace_helpers,
  ../../../../execution_chain/sync/beacon/worker/helpers as worker_helpers,
  ../replay_desc

export
  trace_helpers.idStr,
  trace_helpers.short,
  worker_helpers

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func ageStr*(w: chronos.Duration): string =
  var
    res = newStringOfCap(32)
    nsLeft = w.nanoseconds()

  # Inspired by `chronos/timer.toString()`
  template f(
      pfxChr: static[char];
      pfxLen: static[int];
      ela: static[chronos.Duration];
      sep: static[string];
        ) =
    let n = uint64(nsLeft div ela.nanoseconds())
    when pfxLen == 0:
      let s = if 0 < n: $n else: ""
    else:
      let s = $n
    when 0 < pfxLen:
      res.add pfxChr.repeat(max(0, pfxLen - s.len))
    res.add s
    when pfxLen == 0:
      if 0 < n: res.add sep
    else:
      res.add sep
    nsLeft = nsLeft mod ela.nanoseconds()

  f(' ', 0, chronos.Day, "d ")
  f('0', 2, chronos.Hour, ":")
  f('0', 2, chronos.Minute, ":")
  f('0', 2, chronos.Second, ".")
  f('0', 3, chronos.Millisecond, ".")
  f('0', 3, chronos.Microsecond, "")

  res

func toUpperFirst*(w: string): string =
  if 1 < w.len:
    $w[0].toUpperAscii & w.substr(1)
  else:
    w

# ----------------

template withReplayTypeExpr*(recType: TraceRecType): untyped =
  ## Big switch for allocating `TraceRecType` type dependent replay code
  ## using the replay record layouts.
  ##
  mixin replayTypeExpr

  case recType:
  of TraceRecType(0):
    replayTypeExpr(TraceRecType(0), ReplayPayloadRef)
  of VersionInfo:
    replayTypeExpr(VersionInfo, ReplayVersionInfo)
  of SyncActivated:
    replayTypeExpr(SyncActivated, ReplaySyncActivated)
  of SyncHibernated:
    replayTypeExpr(SyncHibernated, ReplaySyncHibernated)

  of SchedDaemonBegin:
    replayTypeExpr(SchedDaemonBegin, ReplaySchedDaemonBegin)
  of SchedDaemonEnd:
    replayTypeExpr(SchedDaemonEnd, ReplaySchedDaemonEnd)
  of SchedStart:
    replayTypeExpr(SchedStart, ReplaySchedStart)
  of SchedStop:
    replayTypeExpr(SchedStop, ReplaySchedStop)
  of SchedPool:
    replayTypeExpr(SchedPool, ReplaySchedPool)
  of SchedPeerBegin:
    replayTypeExpr(SchedPeerBegin, ReplaySchedPeerBegin)
  of SchedPeerEnd:
    replayTypeExpr(SchedPeerEnd, ReplaySchedPeerEnd)

  of FetchHeaders:
    replayTypeExpr(FetchHeaders, ReplayFetchHeaders)
  of SyncHeaders:
    replayTypeExpr(SyncHeaders, ReplaySyncHeaders)

  of FetchBodies:
    replayTypeExpr(FetchBodies, ReplayFetchBodies)
  of SyncBodies:
    replayTypeExpr(SyncBodies, ReplaySyncBodies)
  of ImportBlock:
    replayTypeExpr(ImportBlock, ReplayImportBlock)
  of SyncBlock:
    replayTypeExpr(SyncBlock, ReplaySyncBlock)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
