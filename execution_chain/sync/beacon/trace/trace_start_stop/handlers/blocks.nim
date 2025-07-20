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
  pkg/[chronicles, chronos, stew/interval_set],
  ../../../../../networking/p2p,
  ../../../../wire_protocol/types,
  ../../[trace_desc, trace_write],
  ./helpers

logScope:
  topics = "beacon trace"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc toBnRange(
    ctx: BeaconCtxRef;
    lst: openArray[Hash32];
    info: static[string];
      ): BnRange =
  ## Resolve block hashes as interval of block numbers
  let rs = BnRangeSet.init()
  for w in lst:
    let h = ctx.hdrCache.get(w).valueOr:
      raiseAssert info & ": Cannot resolve" &
        ", hash=" & w.short
    if rs.merge(h.number,h.number) != 1:
      raiseAssert info & ": dulplicate hash" &
        ", hash=" & w.short & ", number=" & h.bnStr
  rs.ge().expect "valid BnRange"


proc toPeerStr(maybePeer: Opt[BeaconBuddyRef]): string =
  if maybePeer.isOk(): $maybePeer.value.peer else: "n/a"

proc toPeerIdStr(maybePeer: Opt[BeaconBuddyRef]): string =
  if maybePeer.isOk(): maybePeer.value.peerID.short else: "n/a"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetchBodiesTrace*(
    buddy: BeaconBuddyRef;
    req: BlockBodiesRequest;
      ): Future[Result[FetchBodiesData,BeaconError]]
      {.async: (raises: []).} =
  ## Replacement for `getBlockBodies()` handler which in addition writes data
  ## to the output stream for tracing.
  ##
  let
    ivReq = buddy.ctx.toBnRange(req.blockHashes, "getBlockBodiesTrace")
    data = await buddy.ctx.trace.backup.getBlockBodies(buddy, req)

  var tRec: TraceGetBlockBodies
  tRec.init(buddy)
  tRec.req = req
  tRec.ivReq = ivReq
  if data.isOk:
    tRec.fieldAvail = 1
    tRec.fetched = data.value
  else:
    tRec.fieldAvail = 2
    tRec.error = data.error
  buddy.traceWrite tRec

  trace "=BodiesFetch", peer=($buddy.peer), peerID=buddy.peerID.short,
    serial=tRec.serial, ivReq=ivReq.bnStr
  return data


proc importBlockTrace*(
    ctx: BeaconCtxRef;
    maybePeer: Opt[BeaconBuddyRef];
    ethBlock: EthBlock;
    effPeerID: Hash;
      ): Future[Result[Duration,BeaconError]]
      {.async: (raises: []).} =
  ## Replacement for `importBlock()` handler which in addition writes data to
  ## the output stream for tracing.
  ##
  let data = await ctx.trace.backup.importBlock(
    ctx, maybePeer, ethBlock, effPeerID)

  var tRec: TraceImportBlock
  tRec.init(ctx, maybePeer)
  tRec.ethBlock = ethBlock
  tRec.effPeerID = effPeerID
  if data.isOk:
    tRec.fieldAvail = 1
    tRec.elapsed = data.value
  else:
    tRec.fieldAvail = 2
    tRec.error = data.error
  ctx.traceWrite tRec

  trace "=BlocksImport", peer=maybePeer.toPeerStr, peerID=maybePeer.toPeerIdStr,
    effPeerID=tRec.peerID.short,serial=tRec.serial
  return data

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
