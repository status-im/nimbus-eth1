
# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
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
  q.add $base.nSyncPeers
  q.add ($base.syncState).toUpperFirst()
  q.add ($base.chainMode).toUpperFirst()

  q.add $base.baseNum
  q.add $base.latestNum

  if base.chainMode in {collecting,ready,orphan}:
    q.add $base.anteNum
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
                    $base.hdrUnpr.value.hLastNum & ":" &
                    $base.hdrUnpr.value.hLastLen

  if base.blkUnpr.isSome():
    q.add "uBlk=" & $base.blkUnpr.value.bLen & "/" &
                    $base.blkUnpr.value.bChunks & "/" &
                    $base.blkUnpr.value.bLeastNum & ":" &
                    $base.blkUnpr.value.bLeastLen

  if base.peerCtx.isSome() and
     (0 < base.peerCtx.value.nErrors.fetch.hdr or
      0 < base.peerCtx.value.nErrors.fetch.bdy or
      0 < base.peerCtx.value.nErrors.apply.hdr or
      0 < base.peerCtx.value.nErrors.apply.blk):
    q.add "nErr=(" & $base.peerCtx.value.nErrors.fetch.hdr &
               "," & $base.peerCtx.value.nErrors.fetch.bdy &
               ";" & $base.peerCtx.value.nErrors.apply.hdr &
               "," & $base.peerCtx.value.nErrors.apply.blk & ")"

  if base.slowPeer.isSome():
    q.add "slowPeer=" & base.slowPeer.value.short()

# ------------------------------------------------------------------------------
# Private record handlers
# ------------------------------------------------------------------------------

func toStrOops(n: int): seq[string] =
  @["?", $n]

# -----------

func toStrSeq(n: int; w: ReplayVersionInfo): seq[string] =
  var res = newSeqOfCap[string](15)
  res.addX(w.replayLabel, n, w.bag)
  let moan = if w.bag.version < TraceVersionID: "(<" & $TraceVersionID & ")"
             elif TraceVersionID < w.bag.version: "(>" & $TraceVersionID & ")"
             else: ""
  res.add "version=" & $w.bag.version & moan
  res.add "network=" & $w.bag.networkId
  res.add "base=" & $w.bag.baseNum
  res.add "latest=" & $w.bag.latestNum
  res

# -----------

func toStrSeq(n: int; w: ReplaySyncActivated): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w.bag)
  res.add "head=" & $w.bag.head.number
  res.add "finHash=" & w.bag.finHash.short
  res.add "base=" & $w.bag.baseNum
  res.add "latest=" & $w.bag.latestNum
  res

func toStrSeq(n: int; w: ReplaySyncHibernated): seq[string] =
  var res = newSeqOfCap[string](15)
  res.addX(w.replayLabel, n, w.bag)
  res.add "base=" & $w.bag.baseNum
  res.add "latest=" & $w.bag.latestNum
  res

# -----------

func toStrSeq(n: int; w: ReplaySchedDaemonBegin): seq[string] =
  var res = newSeqOfCap[string](15)
  res.addX(w.replayLabel, n, w.bag)
  res

func toStrSeq(n: int; w: ReplaySchedDaemonEnd): seq[string] =
  var res = newSeqOfCap[string](15)
  res.addX(w.replayLabel, n, w.bag)
  res

func toStrSeq(n: int; w: ReplaySchedStart): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w.bag)
  res.add "peer=" & $w.bag.peerIP & ":" & $w.bag.peerPort
  if not w.bag.accept:
    res.add "rejected"
  res

func toStrSeq(n: int; w: ReplaySchedStop): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w.bag)
  res.add "peer=" & $w.bag.peerIP & ":" & $w.bag.peerPort
  res

func toStrSeq(n: int; w: ReplaySchedPool): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w.bag)
  res.add "peer=" & $w.bag.peerIP & ":" & $w.bag.peerPort
  res.add "last=" & $w.bag.last
  res.add "laps=" & $w.bag.laps
  res.add "stop=" & $w.bag.stop
  res

func toStrSeq(n: int; w: ReplaySchedPeerBegin): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w.bag)
  res.add "peer=" & $w.bag.peerIP & ":" & $w.bag.peerPort
  let info = ($w.bag.rank.assessed)
    .multiReplace [("rankingT","t"),("rankingO","o")]
  if w.bag.rank.ranking < 0:
    res.add "rank=" & info
  else:
    res.add "rank=" & info & "(" & $w.bag.rank.ranking & ")"
  res

func toStrSeq(n: int; w: ReplaySchedPeerEnd): seq[string] =
  var res = newSeqOfCap[string](15)
  res.addX(w.replayLabel, n, w.bag)
  res

# -----------

func toStrSeq(n: int; w: ReplayFetchHeaders): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w.bag)
  let
    rLen = w.bag.req.maxResults
    rRev = if w.bag.req.reverse: "rev" else: ""
  if w.bag.req.startBlock.isHash:
    res.add "req=" & w.bag.req.startBlock.hash.short & "[" & $rLen & "]" & rRev
    res.add "bn=" & $w.bag.bn
  else:
    res.add "req=" & $w.bag.req.startBlock.number & "[" & $rLen & "]" & rRev
  if 0 < w.bag.req.skip:
    res.add "skip=" & $w.bag.req.skip
  if w.bag.fetched.isSome():
    res.add "res=[" & $w.bag.fetched.value.packet.headers.len & "]"
    res.add "ela=" & w.bag.fetched.value.elapsed.toStr
  if w.bag.error.isSome():
    if w.bag.error.value.excp.ord == 0:
      res.add "failed"
    else:
      res.add "excp=" & ($w.bag.error.value.excp).substr(1)
    if w.bag.error.value.msg.len != 0:
       res.add "error=" & w.bag.error.value.name &
                         "(" & w.bag.error.value.msg & ")"
    res.add "ela=" & w.bag.error.value.elapsed.toStr
  res

func toStrSeq(n: int; w: ReplaySyncHeaders): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w.bag)
  res


func toStrSeq(n: int; w: ReplayFetchBodies): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w.bag)
  res.add "req=" & $w.bag.ivReq & "[" & $w.bag.req.blockHashes.len & "]"
  if w.bag.fetched.isSome():
    res.add "res=[" & $w.bag.fetched.value.packet.bodies.len & "]"
    res.add "size=" &
      w.bag.fetched.value.packet.bodies.getEncodedLength.uint64.toSI
    res.add "ela=" & w.bag.fetched.value.elapsed.toStr
  if w.bag.error.isSome():
    if w.bag.error.value.excp.ord == 0:
      res.add "failed"
    else:
      res.add "excp=" & ($w.bag.error.value.excp).substr(1)
    if w.bag.error.value.msg.len != 0:
       res.add "error=" &
         w.bag.error.value.name & "(" & w.bag.error.value.msg & ")"
    res.add "ela=" & w.bag.error.value.elapsed.toStr
  res

func toStrSeq(n: int; w: ReplaySyncBodies): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w.bag)
  res


func toStrSeq(n: int; w: ReplayImportBlock): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w.bag)
  res.add "block=" & $w.bag.ethBlock.header.number
  res.add "size=" & w.bag.ethBlock.getEncodedLength.uint64.toSI
  res.add "effPeerID=" & w.bag.effPeerID.short
  if w.bag.elapsed.isSome():
    res.add "ela=" & w.bag.elapsed.value.toStr
  if w.bag.error.isSome():
    if w.bag.error.value.excp.ord == 0:
      res.add "failed"
    else:
      res.add "excp=" & ($w.bag.error.value.excp).substr(1)
    if w.bag.error.value.msg.len != 0:
      res.add "error=" &
        w.bag.error.value.name & "(" & w.bag.error.value.msg & ")"
    res.add "ela=" & w.bag.error.value.elapsed.toStr
  res

func toStrSeq(n: int; w: ReplaySyncBlock): seq[string] =
  var res = newSeqOfCap[string](20)
  res.addX(w.replayLabel, n, w.bag)
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
      lnr.toStrSeq(pyl.T)

  pyl.recType.withReplayTypeExpr()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
