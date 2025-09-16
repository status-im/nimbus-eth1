
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
  pkg/[chronicles, chronos, eth/common, eth/rlp],
  ../../../../execution_chain/utils/prettify,
  ../replay_desc,
  ./reader_helpers

logScope:
  topics = "replay reader"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc addX(
    q: var seq[string];
    info: string;
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

  if base.frameID.isSome():
    q.add base.frameID.value.idStr
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

  if base.peerCtx.isSome():
    q.add $base.peerCtx.value.peerCtrl
    q.add "peerID=" & base.peerCtx.value.peerID.short()
  else:
    q.add "*"
    q.add "*"

  if base.hdrUnpr.isSome():
    q.add "uHdr=" & $base.hdrUnpr.value.hLen & "/" &
                    $base.hdrUnpr.value.hChunks & "/" &
                    $base.hdrUnpr.value.hLastLen & ":" &
                    $base.hdrUnpr.value.hLast.bnStr

  if base.blkUnpr.isSome():
    q.add "uBlk=" & $base.blkUnpr.value.bLen & "/" &
                    $base.blkUnpr.value.bChunks & "/" &
                    $base.blkUnpr.value.bLeast.bnStr & ":" &
                    $base.blkUnpr.value.bLeastLen

  if base.peerCtx.isSome() and
     (0 < base.peerCtx.value.nHdrErrors or
      0 < base.peerCtx.value.nBlkErrors):
    q.add "nErr=(" & $base.peerCtx.value.nHdrErrors &
               "," & $base.peerCtx.value.nBlkErrors & ")"

  if base.slowPeer.isSome():
    q.add "slowPeer=" & base.slowPeer.value.short()

# ------------------------------------------------------------------------------
# Private record handlers
# ------------------------------------------------------------------------------

func toStrOops(n: int): seq[string] =
  @["?", $n]

# -----------

func toStrSeq(n: int; w: TraceVersionInfo): seq[string] =
  var res = newSeqOfCap[string](15)
  res.addX(w.replayLabel, n, w)
  let moan = if w.version < TraceVersionID: "(<" & $TraceVersionID & ")"
             elif TraceVersionID < w.version: "(>" & $TraceVersionID & ")"
             else: ""
  res.add "version=" & $w.version & moan
  res.add "network=" & $w.networkId
  res.add "base=" & w.baseNum.bnStr
  res.add "latest=" & w.latestNum.bnStr
  res

# -----------

func toStrSeq(n: int; w: TraceSyncActvFailed): seq[string] =
  var res = newSeqOfCap[string](15)
  res.addX(w.replayLabel, n, w)
  res.add "base=" & w.baseNum.bnStr
  res.add "latest=" & w.latestNum.bnStr
  res

func toStrSeq(n: int; w: TraceSyncActivated): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w)
  res.add "head=" & w.head.bnStr
  res.add "finHash=" & w.finHash.short
  res.add "base=" & w.baseNum.bnStr
  res.add "latest=" & w.latestNum.bnStr
  res

func toStrSeq(n: int; w: TraceSyncHibernated): seq[string] =
  var res = newSeqOfCap[string](15)
  res.addX(w.replayLabel, n, w)
  res.add "base=" & w.baseNum.bnStr
  res.add "latest=" & w.latestNum.bnStr
  res

# -----------

func toStrSeq(n: int; w: TraceSchedDaemonBegin): seq[string] =
  var res = newSeqOfCap[string](15)
  res.addX(w.replayLabel, n, w)
  res

func toStrSeq(n: int; w: TraceSchedDaemonEnd): seq[string] =
  var res = newSeqOfCap[string](15)
  res.addX(w.replayLabel, n, w)
  res

func toStrSeq(n: int; w: TraceSchedStart): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w)
  res.add "peer=" & $w.peerIP & ":" & $w.peerPort
  if not w.accept:
    res.add "rejected"
  res

func toStrSeq(n: int; w: TraceSchedStop): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w)
  res.add "peer=" & $w.peerIP & ":" & $w.peerPort
  res

func toStrSeq(n: int; w: TraceSchedPool): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w)
  res.add "peer=" & $w.peerIP & ":" & $w.peerPort
  res.add "last=" & $w.last
  res.add "laps=" & $w.laps
  res.add "stop=" & $w.stop
  res

func toStrSeq(n: int; w: TraceSchedPeerBegin): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w)
  res.add "peer=" & $w.peerIP & ":" & $w.peerPort
  res

func toStrSeq(n: int; w: TraceSchedPeerEnd): seq[string] =
  var res = newSeqOfCap[string](15)
  res.addX(w.replayLabel, n, w)
  res

# -----------

func toStrSeq(n: int; w: TraceFetchHeaders): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w)
  let
    rLen = w.req.maxResults
    rRev = if w.req.reverse: "rev" else: ""
  if w.req.startBlock.isHash:
    res.add "req=" & w.req.startBlock.hash.short & "[" & $rLen & "]" & rRev
  else:
    res.add "req=" & w.req.startBlock.number.bnStr & "[" & $rLen & "]" & rRev
  if 0 < w.req.skip:
    res.add "skip=" & $w.req.skip
  if w.fetched.isSome():
    res.add "res=[" & $w.fetched.value.packet.headers.len & "]"
    res.add "ela=" & w.fetched.value.elapsed.toStr
  if w.error.isSome():
    if w.error.value.excp.ord == 0:
      res.add "failed"
    else:
      res.add "excp=" & ($w.error.value.excp).substr(1)
    if w.error.value.msg.len != 0:
       res.add "error=" & w.error.value.name & "(" & w.error.value.msg & ")"
    res.add "ela=" & w.error.value.elapsed.toStr
  res

func toStrSeq(n: int; w: TraceSyncHeaders): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w)
  res


func toStrSeq(n: int; w: TraceFetchBodies): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w)
  res.add "req=" & w.ivReq.bnStr & "[" & $w.req.blockHashes.len & "]"
  if w.fetched.isSome():
    res.add "res=[" & $w.fetched.value.packet.bodies.len & "]"
    res.add "size=" & w.fetched.value.packet.bodies.getEncodedLength.uint64.toSI
    res.add "ela=" & w.fetched.value.elapsed.toStr
  if w.error.isSome():
    if w.error.value.excp.ord == 0:
      res.add "failed"
    else:
      res.add "excp=" & ($w.error.value.excp).substr(1)
    if w.error.value.msg.len != 0:
       res.add "error=" & w.error.value.name & "(" & w.error.value.msg & ")"
    res.add "ela=" & w.error.value.elapsed.toStr
  res

func toStrSeq(n: int; w: TraceSyncBodies): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w)
  res


func toStrSeq(n: int; w: TraceImportBlock): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w)
  res.add "block=" & w.ethBlock.bnStr
  res.add "size=" & w.ethBlock.getEncodedLength.uint64.toSI
  res.add "effPeerID=" & w.effPeerID.short
  if w.elapsed.isSome():
    res.add "ela=" & w.elapsed.value.toStr
  if w.error.isSome():
    if w.error.value.excp.ord == 0:
      res.add "failed"
    else:
      res.add "excp=" & ($w.error.value.excp).substr(1)
    if w.error.value.msg.len != 0:
       res.add "error=" & w.error.value.name & "(" & w.error.value.msg & ")"
    res.add "ela=" & w.error.value.elapsed.toStr
  res

func toStrSeq(n: int; w: TraceSyncBlock): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w)
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
  ## Convert the internal capture object argument `pyl` to a list of
  ## printable strings.
  ##
  template replayTypeExpr(t: TraceRecType, T: type): untyped =
    when t == TraceRecType(0):
      lnr.toStrOops()
    else:
      lnr.toStrSeq(pyl.T.data)

  pyl.recType.withReplayTypeExpr()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
