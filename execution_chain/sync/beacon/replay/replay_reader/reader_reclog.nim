# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Replay environment

{.push raises:[].}

import
  std/[net, strformat, strutils, syncio],
  pkg/[chronicles, chronos, eth/common],
  ../[replay_desc, replay_helpers]

logScope:
  topics = "replay reader"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc addX(
    q: var seq[string];
    info: static[string];
    lnr: int;
    base: TraceRecBase;
      ) =
  ## Output header
  q.add base.time.ageStr()
  q.add info
  if 0 < lnr and base.serial != lnr.uint:
    q.add $base.serial & "!" & $lnr
  else:
    q.add $base.serial

  if 0 < base.frameID:
    q.add base.frameID.idStr
  else:
    q.add "*"
  q.add $base.nPeers
  q.add ($base.syncState).toUpperFirst()
  q.add ($base.chainMode).toUpperFirst()

  q.add base.baseNum.bnStr()
  q.add base.latestNum.bnStr()

  if base.chainMode in {collecting,ready,orphan}:
    q.add base.antecedent.bnStr()
  else:
    q.add "*"

  q.add (if (base.stateAvail and 1) != 0: $base.peerCtrl else: "*")
  q.add (if (base.stateAvail and 2) != 0: "peerID=" & base.peerID.short()
         else: "*")

  if 0 < base.hdrUnprChunks:
    q.add "uHdr=" & $base.hdrUnprLen & "/" &
                    $base.hdrUnprChunks & "/" &
                    $base.hdrUnprLastLen & ":" &
                    $base.hdrUnprLast.bnStr

  if 0 < base.blkUnprChunks:
    q.add "uBlk=" & $base.blkUnprLen & "/" &
                    $base.blkUnprChunks & "/" &
                    $base.blkUnprLeast.bnStr & ":" &
                    $base.blkUnprLeastLen

  if (base.stateAvail and 12) != 0 and
     (0 < base.nHdrErrors or 0 < base.nBlkErrors):
    q.add "nErr=(" & $base.nHdrErrors & "," & $base.nBlkErrors & ")"

  if (base.stateAvail and 16) != 0:
    q.add "slowPeer=" & base.slowPeer.short()

# ------------------------------------------------------------------------------
# Private record handlers
# ------------------------------------------------------------------------------

func toStrOops(n: int): seq[string] =
  @["?", $n]

# -----------

func toStrSeq(n: int; w: TraceVersionInfo): seq[string] =
  var res = newSeqOfCap[string](15)
  res.addX("=Version", n, w)
  res.add "version=" & $w.version
  res.add "network=" & $w.networkId
  res

# -----------

func toStrSeq(n: int; w: TraceSyncActvFailed): seq[string] =
  var res = newSeqOfCap[string](15)
  res.addX("=ActvFailed", n, w)
  res

func toStrSeq(n: int; w: TraceSyncActivated): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX("=Activated", n, w)
  res.add "head=" & w.head.bnStr
  res.add "finHash=" & w.finHash.short
  res

func toStrSeq(n: int; w: TraceSyncHibernated): seq[string] =
  var res = newSeqOfCap[string](15)
  res.addX("=Suspended", n, w)
  res

# -----------

func toStrSeq(n: int; w: TraceSchedDaemonBegin): seq[string] =
  var res = newSeqOfCap[string](15)
  res.addX("+Daemon", n, w)
  res

func toStrSeq(n: int; w: TraceSchedDaemonEnd): seq[string] =
  var res = newSeqOfCap[string](15)
  res.addX("-Daemon", n, w)
  res

func toStrSeq(n: int; w: TraceSchedStart): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX("=StartPeer", n, w)
  res.add "peer=" & $w.peerIP & ":" & $w.peerPort
  if not w.accept:
    res.add "rejected"
  res

func toStrSeq(n: int; w: TraceSchedStop): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX("=StopPeer", n, w)
  res.add "peer=" & $w.peerIP & ":" & $w.peerPort
  res

func toStrSeq(n: int; w: TraceSchedPool): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX("=Pool", n, w)
  res.add "peer=" & $w.peerIP & ":" & $w.peerPort
  res.add "last=" & $w.last
  res.add "laps=" & $w.laps
  res.add "stop=" & $w.stop
  res

func toStrSeq(n: int; w: TraceSchedPeerBegin): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX("+Peer", n, w)
  res.add "peer=" & $w.peerIP & ":" & $w.peerPort
  res

func toStrSeq(n: int; w: TraceSchedPeerEnd): seq[string] =
  var res = newSeqOfCap[string](15)
  res.addX("-Peer", n, w)
  res

# -----------

func toStrSeq(n: int; w: TraceFetchHeaders): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX("=HeadersFetch", n, w)
  let
    rLen = w.req.maxResults
    rRev = if w.req.reverse: "rev" else: ""
  if w.req.startBlock.isHash:
    res.add "req=" & w.req.startBlock.hash.short & "[" & $rLen & "]" & rRev
  else:
    res.add "req=" & w.req.startBlock.number.bnStr & "[" & $rLen & "]" & rRev
  if 0 < w.req.skip:
    res.add "skip=" & $w.req.skip
  if (w.fieldAvail and 1) != 0:
    res.add "res=[" & $w.fetched.packet.headers.len & "]"
    res.add "ela=" & w.fetched.elapsed.toStr
  if (w.fieldAvail and 2) != 0:
    if w.error.excp.ord == 0:
      res.add "failed"
    else:
      res.add "excp=" & ($w.error.excp).substr(1)
    if w.error.msg.len != 0:
       res.add "error=" & w.error.name & "(" & w.error.msg & ")"
    res.add "ela=" & w.error.elapsed.toStr
  res

func toStrSeq(n: int; w: TraceSyncHeaders): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX("=HeadersSync", n, w)
  res


func toStrSeq(n: int; w: TraceFetchBodies): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX("=BodiesFetch", n, w)
  res.add "req=" & w.ivReq.bnStr & "[" & $w.req.blockHashes.len & "]"
  if (w.fieldAvail and 1) != 0:
    res.add "res=[" & $w.fetched.packet.bodies.len & "]"
    res.add "ela=" & w.fetched.elapsed.toStr
  if (w.fieldAvail and 2) != 0:
    if w.error.excp.ord == 0:
      res.add "failed"
    else:
      res.add "excp=" & ($w.error.excp).substr(1)
    if w.error.msg.len != 0:
       res.add "error=" & w.error.name & "(" & w.error.msg & ")"
    res.add "ela=" & w.error.elapsed.toStr
  res

func toStrSeq(n: int; w: TraceSyncBodies): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX("=BodiesSync", n, w)
  res


func toStrSeq(n: int; w: TraceImportBlock): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX("=BlockImport", n, w)
  res.add "block=" & w.ethBlock.bnStr
  res.add "effPeerID=" & w.effPeerID.short
  if (w.fieldAvail and 1) != 0:
    res.add "ela=" & w.elapsed.toStr
  if (w.fieldAvail and 2) != 0:
    if w.error.excp.ord == 0:
      res.add "failed"
    else:
      res.add "excp=" & ($w.error.excp).substr(1)
    if w.error.msg.len != 0:
       res.add "error=" & w.error.name & "(" & w.error.msg & ")"
    res.add "ela=" & w.error.elapsed.toStr
  res

func toStrSeq(n: int; w: TraceSyncBlock): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX("=BlockSync", n, w)
  res

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc recLogPrint*(fh: File): ReplayRecLogPrintFn =
  ## The function provides an example for a call back pretty printer
  ## for `lineLog()`.
  return proc(w: seq[string]) =
    try:
      block doFields:
        if w.len <= 9:
          fh.write w.join(" ")
          break doFields

        # at least 9 fields
        fh.write "" &
          &"{w[0]:>18} {w[1]:<13} {w[2]:>6} " &
          &"{w[3]:>5} {w[4]:>2} {w[5]:<13} " &
          &"{w[6]:<10} {w[7]:>10} {w[8]:>10} " &
          &"{w[9]:>10}"

        if w.len <= 11:
          if w.len == 11:
            fh.write " "
            fh.write w[10]
          break doFields

        # at least 12 fields
        if w.len <= 12:
          fh.write &" {w[10]:<10} "
          fh.write w[11]
          break doFields

        # more than 12 fields
        fh.write &" {w[10]:<10} {w[11]:<15}"

        # at least 13 fields
        fh.write " "
        fh.write w[12 ..< w.len].join(" ")

      fh.write "\n"
    except IOError as e:
      warn "lineLogPrint(): Exception while writing to file",
        name=($e.name), msg=e.msg

# -----------

func recLogToStrEnd*(n: int): seq[string] =
  @[".", $n]

proc recLogToStrList*(pyl: ReplayPayloadRef; lnr = 0): seq[string] =
  case pyl.recType:
  of TrtOops:
    lnr.toStrOops()

  of TrtVersionInfo:
    lnr.toStrSeq(pyl.ReplayVersionInfo.data)

  of TrtSyncActvFailed:
    lnr.toStrSeq(pyl.ReplaySyncActvFailed.data)
  of TrtSyncActivated:
    lnr.toStrSeq(pyl.ReplaySyncActivated.data)
  of TrtSyncHibernated:
    lnr.toStrSeq(pyl.ReplaySyncHibernated.data)

  of TrtSchedDaemonBegin:
    lnr.toStrSeq(pyl.ReplaySchedDaemonBegin.data)
  of TrtSchedDaemonEnd:
    lnr.toStrSeq(pyl.ReplaySchedDaemonEnd.data)
  of TrtSchedStart:
    lnr.toStrSeq(pyl.ReplaySchedStart.data)
  of TrtSchedStop:
    lnr.toStrSeq(pyl.ReplaySchedStop.data)
  of TrtSchedPool:
    lnr.toStrSeq(pyl.ReplaySchedPool.data)
  of TrtSchedPeerBegin:
    lnr.toStrSeq(pyl.ReplaySchedPeerBegin.data)
  of TrtSchedPeerEnd:
    lnr.toStrSeq(pyl.ReplaySchedPeerEnd.data)

  of TrtFetchHeaders:
    lnr.toStrSeq(pyl.ReplayFetchHeaders.data)
  of TrtSyncHeaders:
    lnr.toStrSeq(pyl.ReplaySyncHeaders.data)

  of TrtFetchBodies:
    lnr.toStrSeq(pyl.ReplayFetchBodies.data)
  of TrtSyncBodies:
    lnr.toStrSeq(pyl.ReplaySyncBodies.data)

  of TrtImportBlock:
    lnr.toStrSeq(pyl.ReplayImportBlock.data)
  of TrtSyncBlock:
    lnr.toStrSeq(pyl.ReplaySyncBlock.data)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
