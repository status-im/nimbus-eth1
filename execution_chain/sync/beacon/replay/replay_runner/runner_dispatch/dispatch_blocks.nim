# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Replay runner

{.push raises:[].}

import
  pkg/[chronicles, chronos, eth/common, stew/interval_set],
  ../../../../wire_protocol,
  ../../replay_desc,
  ./dispatch_helpers

logScope:
  topics = "replay runner"

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

proc bnStr(
    lst: openArray[Hash32];
    buddy: BeaconBuddyRef;
    info: static[string];
      ): string =
  buddy.ctx.toBnRange(lst, info).bnStr

proc toStr(e: BeaconError; anyTime = false): string =
  "(" & $e[0] &
    "," & $e[1] &
    "," & $e[2] &
    "," & (if anyTime: "*" else: e[3].toStr) &
    ")"

# ----------------

func getResponse(
    instr: TraceFetchBodies;
      ): Result[FetchBodiesData,BeaconError] =
  if (instr.fieldAvail and 1) != 0:
    ok(instr.fetched)
  else:
    err(instr.error)

func getResponse(
    instr: TraceImportBlock;
      ): Result[Duration,BeaconError] =
  if (instr.fieldAvail and 1) != 0:
    ok(instr.elapsed)
  else:
    err(instr.error)

func getBeaconError(e: ReplayWaitError): BeaconError =
  (e[0], e[1], e[2], Duration())

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc importBlockHandlerImpl(
    desc: ReplayDaemonRef|ReplayBuddyRef;
    ethBlock: EthBlock;
    effPeerID: Hash;
    info: static[string];
      ): Future[Result[Duration,BeaconError]]
      {.async: (raises: []).} =

  let
    n = desc.iNum
    peer = desc.peerStr
    peerID = desc.peerIdStr
    
  var data: TraceImportBlock
  desc.withInstr(typeof data, info):
    if not instr.isAvailable():
      return err(iError.getBeaconError()) # Shutdown?

    if effPeerID != instr.effPeerID:
      raiseAssert info & ": eff. peer arguments differ" &
        ", n=" & $n &
        ", serial=" & $instr.serial &
        ", peer=" & $peer &
        ", peerID=" & $peerID &
        ", ethBlock=" & ethBlock.bnStr &
        # -----
        ", effPeerID=" & effPeerID.short &
        ", expected=" & instr.effPeerID.short

    if ethBlock != instr.ethBlock:
      raiseAssert info & ": block arguments differ" &
        ", n=" & $n &
        ", serial=" & $instr.serial &
        ", peer=" & $peer &
        ", peerID=" & $peerID &
        ", effPeerID=" & effPeerID.short &
        # -----
        ", ethBlock=" & ethBlock.bnStr &
        ", expected=%" & instr.ethBlock.bnStr &
        # -----
        ", ethBlock=%" & ethBlock.computeRlpHash.short &
        ", expected=%" & instr.ethBlock.computeRlpHash.short
    data = instr

  let
    ctx = desc.run.ctx
    rpl = ctx.replay
  if not rpl.runner.fakeImport:
    when desc is ReplayDaemonRef:
      let maybePeer = results.Opt[BeaconBuddyRef].err()
    elif desc is ReplayBuddyRef:
      let maybePeer = results.Opt[BeaconBuddyRef].ok(desc)

    let rc = await rpl.backup.importBlock(ctx, maybePeer, ethBlock, effPeerID)
    if rc.isErr or (data.fieldAvail and 2) != 0:
      const info = info & ": result values differ"
      let serial = data.serial
      if rc.isErr and (data.fieldAvail and 2) == 0:
        warn info, n, serial, peer, peerID,
          got="err" & rc.error.toStr, expected="ok"
      elif rc.isOk and (data.fieldAvail and 2) != 0: 
        warn info, n, serial, peer, peerID,
          got="ok", expected="err" & data.error.toStr(true)
      elif rc.error.excp !=  data.error.excp or
           rc.error.msg != data.error.msg:
        warn info, n, serial, peer, peerID,
          got="err" & rc.error.toStr, expected="err" & data.error.toStr(true)

  desc.withInstr(TraceSyncBlock, info):
    if not instr.isAvailable():
      return err(iError.getBeaconError()) # Shutdown?
    discard # no-op, visual alignment

  return data.getResponse()

# ------------------------------------------------------------------------------
# Public dispatcher handlers
# ------------------------------------------------------------------------------

proc fetchBodiesHandler*(
    buddy: BeaconBuddyRef;
    req: BlockBodiesRequest;
      ): Future[Result[FetchBodiesData,BeaconError]]
      {.async: (raises: []).} =
  const info = "&fetchBodies"
  let buddy = ReplayBuddyRef(buddy)

  var data: TraceFetchBodies
  buddy.withInstr(typeof data, info):
    if not instr.isAvailable():
      return err(iError.getBeaconError()) # Shutdown?
    if req != instr.req:
      raiseAssert info & ": arguments differ" &
        ", serial=" & $instr.serial &
        ", peer=" & $buddy.peer &
        # -----
        ", nBlockHashes=" & $req.blockHashes.len &
        ", expected=" & $instr.ivReq.len &
        # -----
        ", blockHashes=" & req.blockHashes.bnStr(buddy, info)  &
        ", expected=" & instr.ivReq.bnStr
    data = instr

  buddy.withInstr(TraceSyncBodies, info):
    if not instr.isAvailable():
      return err(iError.getBeaconError()) # Shutdown?
    discard # no-op, visual alignment

  return data.getResponse()


proc importBlockHandler*(
    ctx: BeaconCtxRef;
    maybePeer: Opt[BeaconBuddyRef];
    ethBlock: EthBlock;
    effPeerID: Hash;
      ): Future[Result[Duration,BeaconError]]
      {.async: (raises: []).} =
  ## Replacement for `importBlock()` handler.
  const info = "&importBlock"

  if maybePeer.isSome():
    let buddy = ReplayBuddyRef(maybePeer.value)
    return await buddy.importBlockHandlerImpl(ethBlock, effPeerID, info)

  # Verify that the daemon is properly initialised
  let
    run = ctx.replay.runner
    daemon = run.daemon
  if daemon.isNil:
    raiseAssert info & ": system error (no daemon)" &
      ", serial=" &
      ", peer=n/a" &
      ", effPeerID=" & effPeerID.short

  return await daemon.importBlockHandlerImpl(ethBlock, effPeerID, info)

# ------------------------------------------------------------------------------
# Public functions, data feed
# ------------------------------------------------------------------------------

proc sendBodies*(
    run: ReplayRunnerRef;
    instr: TraceFetchBodies|TraceSyncBodies;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Stage bodies request/response data
  let buddy = run.getPeer(instr, info).expect "valid sync peer"
  discard buddy.pushInstr(instr, info)

proc sendBlock*(
    run: ReplayRunnerRef;
    instr: TraceImportBlock|TraceSyncBlock;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Stage block request/response data
  if (instr.stateAvail and 2) != 0:
    # So it was captured run from a sync peer
    let buddy = run.getPeer(instr, info).expect "valid sync peer"
    discard buddy.pushInstr(instr, info)

  # Verify that the daemon is properly initialised
  elif run.daemon.isNil:
    raiseAssert info & ": system error (no daemon)" &
      ", serial=" & $instr.serial &
      ", peer=n/a"

  else:
    discard run.daemon.pushInstr(instr, info)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
