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
  ../../../../execution_chain/networking/p2p,
  ../trace_desc,
  ./[setup_helpers, setup_write]

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

proc schedDaemonTrace*(
    ctx: BeaconCtxRef;
      ): Future[Duration]
      {.async: (raises: []).} =
  ## Replacement for `schedDaemon()` handler which in addition
  ## write data to the output stream for tracing.
  ##
  var tBeg: TraceSchedDaemonBegin
  tBeg.init ctx
  tBeg.frameID = Opt.some(tBeg.serial)
  ctx.traceWrite tBeg

  trace "+Daemon", serial=tBeg.serial, frameID=tBeg.frameID.value.idStr,
    syncState=tBeg.syncState

  let idleTime = await ctx.trace.backup.schedDaemon ctx

  var tEnd: TraceSchedDaemonEnd
  tEnd.init ctx
  tEnd.frameID = Opt.some(tBeg.serial) # refers back to `tBeg` capture
  tEnd.idleTime = idleTime
  ctx.traceWrite tEnd

  if 0 < tEnd.serial:
    trace "-Daemon", serial=tEnd.serial, frameID=tEnd.frameID.value.idStr,
      syncState=tBeg.syncState, idleTime=idleTime.toStr
  else:
    trace "-Daemon (blind)", serial="n/a", frameID=tEnd.frameID.value.idStr,
      syncState=tBeg.syncState, idleTime=idleTime.toStr

  return idleTime


proc schedStartTrace*(buddy: BeaconBuddyRef): bool =
  ## Similar to `schedDaemonTrace()`
  ##
  let
    ctx = buddy.ctx
    acceptOk = ctx.trace.backup.schedStart(buddy)

  if not ctx.hibernate:
    var tRec: TraceSchedStart
    tRec.init buddy
    tRec.frameID = Opt.some(tRec.serial)
    tRec.peerIP = buddy.getIP()
    tRec.peerPort = buddy.getPort()
    tRec.accept = acceptOk
    buddy.traceWrite tRec

    trace "=StartPeer", peer=($buddy.peer), peerID=buddy.peerID.short,
      serial=tRec.serial, frameID=tRec.frameID.value.idStr,
      syncState=tRec.syncState

  acceptOk


proc schedStopTrace*(buddy: BeaconBuddyRef) =
  ## Similar to `schedDaemonTrace()`
  ##
  let ctx = buddy.ctx

  ctx.trace.backup.schedStop(buddy)

  if not ctx.hibernate:
    var tRec: TraceSchedStop
    tRec.init buddy
    tRec.frameID = Opt.some(tRec.serial)
    tRec.peerIP = buddy.getIP()
    tRec.peerPort = buddy.getPort()
    buddy.traceWrite tRec

    trace "=StopPeer", peer=($buddy.peer), peerID=buddy.peerID.short,
      serial=tRec.serial, frameID=tRec.frameID.value.idStr,
      syncState=tRec.syncState


proc schedPoolTrace*(buddy: BeaconBuddyRef; last: bool; laps: int): bool =
  ## Similar to `schedDaemonTrace()`
  ##
  let stopOk = buddy.ctx.trace.backup.schedPool(buddy, last, laps)

  var tRec: TraceSchedPool
  tRec.init buddy
  tRec.frameID = Opt.some(tRec.serial)
  tRec.peerIP = buddy.getIP()
  tRec.peerPort = buddy.getPort()
  tRec.last = last
  tRec.laps = laps.uint
  tRec.stop = stopOk
  buddy.traceWrite tRec

  trace "=Pool", peer=($buddy.peer), peerID=buddy.peerID.short,
    serial=tRec.serial

  stopOk


proc schedPeerTrace*(
    buddy: BeaconBuddyRef;
      ): Future[Duration]
      {.async: (raises: []).} =
  ## Similar to `schedDaemonTrace()`
  ##
  let
    ctx = buddy.ctx
    noisy = not ctx.hibernate

  var tBeg: TraceSchedPeerBegin
  if noisy:
    tBeg.init buddy
    tBeg.frameID = Opt.some(tBeg.serial)
    tBeg.peerIP = buddy.getIP()
    tBeg.peerPort = buddy.getPort()
    buddy.traceWrite tBeg

    trace "+Peer", peer=($buddy.peer), peerID=buddy.peerID.short,
      serial=tBeg.serial, frameID=tBeg.frameID.value.idStr,
      syncState=tBeg.syncState

  let idleTime = await ctx.trace.backup.schedPeer(buddy)

  if noisy:
    var tEnd: TraceSchedPeerEnd
    tEnd.init buddy
    tEnd.frameID = Opt.some(tBeg.serial) # refers back to `tBeg` capture
    tEnd.idleTime = idleTime
    buddy.traceWrite tEnd

    trace "-Peer", peer=($buddy.peer), peerID=buddy.peerID.short,
      serial=tEnd.serial, frameID=tEnd.frameID.value.idStr,
      syncState=tBeg.syncState, idleTime=idleTime.toStr

  return idleTime

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
