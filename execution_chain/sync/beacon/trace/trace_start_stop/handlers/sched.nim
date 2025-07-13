# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Overlay handler for trace environment

{.push raises:[].}

import
  pkg/[chronicles, chronos],
  ../../../../../networking/p2p,
  ../../[trace_desc, trace_write],
  ./helpers

logScope:
  topics = "beacon trace"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc getIP(buddy: BeaconBuddyRef): IpAddress =
  buddy.peer.remote.node.address.ip

proc getPort(buddy: BeaconBuddyRef): Port =
  let peer = buddy.peer
  if peer.remote.node.address.tcpPort != Port(0):
    peer.remote.node.address.tcpPort
  else:
    peer.remote.node.address.udpPort

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc schedDaemonTrace*(ctx: BeaconCtxRef) {.async: (raises: []).} =
  ## Replacement for `schedDaemon()` handler which in addition
  ## write data to the output stream for tracing.
  ##
  var tBeg: TraceSchedDaemonBegin
  tBeg.init ctx
  ctx.traceWrite tBeg

  trace "+Daemon", serial=tBeg.serial, envID=tBeg.envID.idStr,
    syncState=tBeg.syncState

  await ctx.trace.backup.schedDaemon ctx

  var tEnd: TraceSchedDaemonEnd
  tEnd.init(ctx, tBeg.envID) # envID refers back to `tBeg` capture
  ctx.traceWrite tEnd

  trace "-Daemon", serial=tEnd.serial, envID=tEnd.envID.idStr,
    syncState=tBeg.syncState


proc schedStartTrace*(buddy: BeaconBuddyRef): bool =
  ## Similar to `schedDaemonTrace()`
  ##
  let
    ctx = buddy.ctx
    acceptOk = ctx.trace.backup.schedStart(buddy)

  if not ctx.hibernate:
    var tRec: TraceSchedStart
    tRec.init buddy
    tRec.peerIP = buddy.getIP()
    tRec.peerPort = buddy.getPort()
    tRec.accept = acceptOk
    buddy.traceWrite tRec

    trace "=StartPeer", peer=($buddy.peer), peerID=buddy.peerID.short,
      serial=tRec.serial, envID=tRec.envID.idStr

  acceptOk


proc schedStopTrace*(buddy: BeaconBuddyRef) =
  ## Similar to `schedDaemonTrace()`
  ##
  let ctx = buddy.ctx

  ctx.trace.backup.schedStop(buddy)

  if not ctx.hibernate:
    var tRec: TraceSchedStop
    tRec.init buddy
    tRec.peerIP = buddy.getIP()
    tRec.peerPort = buddy.getPort()
    buddy.traceWrite tRec

    trace "=StopPeer", peer=($buddy.peer), peerID=buddy.peerID.short,
      serial=tRec.serial, envID=tRec.envID.idStr


proc schedPoolTrace*(buddy: BeaconBuddyRef; last: bool; laps: int): bool =
  ## Similar to `schedDaemonTrace()`
  ##
  let stopOk = buddy.ctx.trace.backup.schedPool(buddy, last, laps)

  var tRec: TraceSchedPool
  tRec.init buddy
  tRec.peerIP = buddy.getIP()
  tRec.peerPort = buddy.getPort()
  tRec.last = last
  tRec.laps = laps.uint
  tRec.stop = stopOk
  buddy.traceWrite tRec

  trace "=Pool", peer=($buddy.peer), peerID=buddy.peerID.short,
    serial=tRec.serial, envID=tRec.envID.idStr

  stopOk


proc schedPeerTrace*(buddy: BeaconBuddyRef) {.async: (raises: []).} =
  ## Similar to `schedDaemonTrace()`
  ##
  let
    ctx = buddy.ctx
    noisy = not ctx.hibernate

  var tBeg: TraceSchedPeerBegin
  if noisy:
    tBeg.init buddy
    tBeg.peerIP = buddy.getIP()
    tBeg.peerPort = buddy.getPort()
    buddy.traceWrite tBeg

    trace "+Peer", peer=($buddy.peer), peerID=buddy.peerID.short,
      serial=tBeg.serial, envID=tBeg.envID.idStr, syncState=tBeg.syncState

  await ctx.trace.backup.schedPeer(buddy)

  if noisy:
    var tEnd: TraceSchedPeerEnd
    tEnd.init(buddy, tBeg.envID) # envID refers back to `tBeg` capture
    buddy.traceWrite tEnd

    trace "-Peer", peer=($buddy.peer), peerID=buddy.peerID.short,
      serial=tEnd.serial, envID=tEnd.envID.idStr, syncState=tBeg.syncState

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
