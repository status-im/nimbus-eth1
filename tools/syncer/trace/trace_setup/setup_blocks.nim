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
  ../../../../execution_chain/networking/p2p,
  ../../../../execution_chain/sync/wire_protocol/types,
  ../trace_desc,
  ./[setup_helpers, setup_write]

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
    ivReq = buddy.ctx.toBnRange(req.blockHashes, "fetchBodiesTrace")
    data = await buddy.ctx.trace.backup.getBlockBodies(buddy, req)

  var tRec: TraceFetchBodies
  tRec.init buddy
  tRec.req = req
  tRec.ivReq = ivReq
  if data.isOk:
    tRec.fetched = Opt.some(data.value)
  else:
    tRec.error = Opt.some(data.error)
  buddy.traceWrite tRec

  trace "=BodiesFetch", peer=($buddy.peer), peerID=buddy.peerID.short,
    serial=tRec.serial, ivReq=ivReq.bnStr
  return data

proc syncBodiesTrace*(
    buddy: BeaconBuddyRef;
      ) =
  ## Replacement for `syncBlockBodies()` handler.
  var tRec: TraceSyncBodies
  tRec.init buddy
  buddy.traceWrite tRec

  trace "=BodiesSync", peer=($buddy.peer), peerID=buddy.peerID.short,
    serial=tRec.serial


proc importBlockTrace*(
    buddy: BeaconBuddyRef;
    ethBlock: EthBlock;
    effPeerID: Hash;
      ): Future[Result[Duration,BeaconError]]
      {.async: (raises: []).} =
  ## Replacement for `importBlock()` handler which in addition writes data to
  ## the output stream for tracing.
  ##
  let data = await buddy.ctx.trace.backup.importBlock(
    buddy, ethBlock, effPeerID)

  var tRec: TraceImportBlock
  tRec.init buddy
  tRec.ethBlock = ethBlock
  tRec.effPeerID = effPeerID
  if data.isOk:
    tRec.elapsed = Opt.some(data.value)
  else:
    tRec.error = Opt.some(data.error)
  buddy.traceWrite tRec

  trace "=BlockImport", peer=($buddy.peer), peerID=buddy.peerID.short,
    effPeerID=effPeerID.short, serial=tRec.serial
  return data

proc syncBlockTrace*(
    buddy: BeaconBuddyRef;
      ) =
  ## Replacement for `syncImportBlock()` handler.
  var tRec: TraceSyncBlock
  tRec.init buddy
  buddy.traceWrite tRec

  trace "=BlockSync", peer=($buddy.peer), peerID=buddy.peerID.short,
    serial=tRec.serial

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
