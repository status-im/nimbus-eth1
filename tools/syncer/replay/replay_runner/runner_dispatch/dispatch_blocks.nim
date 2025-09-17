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
  ../../../../../execution_chain/sync/wire_protocol,
  ../runner_desc,
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
    instr: ReplayFetchBodies;
      ): Result[FetchBodiesData,BeaconError] =
  if instr.bag.fetched.isSome():
    ok(instr.bag.fetched.value)
  elif instr.bag.error.isSome():
    err(instr.bag.error.value)
  else:
    err((ENoException,"","Missing fetch bodies return code",Duration()))

func getResponse(
    instr: ReplayImportBlock;
      ): Result[Duration,BeaconError] =
  if instr.bag.elapsed.isSome():
    ok(instr.bag.elapsed.value)
  elif instr.bag.error.isSome():
    err(instr.bag.error.value)
  else:
    err((ENoException,"","Missing block import return code",Duration()))

func getBeaconError(e: ReplayWaitError): BeaconError =
  (e[0], e[1], e[2], Duration())

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

  var data: ReplayFetchBodies
  buddy.withInstr(typeof data, info):
    if not instr.isAvailable():
      return err(iError.getBeaconError()) # Shutdown?
    if req != instr.bag.req:
      raiseAssert info & ": arguments differ" &
        ", serial=" & $instr.bag.serial &
        ", peer=" & $buddy.peer &
        # -----
        ", nBlockHashes=" & $req.blockHashes.len &
        ", expected=" & $instr.bag.ivReq.len &
        # -----
        ", blockHashes=" & req.blockHashes.bnStr(buddy, info)  &
        ", expected=" & instr.bag.ivReq.bnStr
    data = instr

  buddy.withInstr(ReplaySyncBodies, info):
    if not instr.isAvailable():
      return err(iError.getBeaconError()) # Shutdown?
    discard # no-op, visual alignment

  return data.getResponse()


proc importBlockHandler*(
    buddy: BeaconBuddyRef;
    ethBlock: EthBlock;
    effPeerID: Hash;
      ): Future[Result[Duration,BeaconError]]
      {.async: (raises: []).} =
  const info = "&importBlock"

  let
    buddy = ReplayBuddyRef(buddy)
    n = buddy.iNum
    peer = buddy.peerStr
    peerID = buddy.peerIdStr
    
  var data: ReplayImportBlock
  buddy.withInstr(typeof data, info):
    if not instr.isAvailable():
      return err(iError.getBeaconError()) # Shutdown?

    if effPeerID != instr.bag.effPeerID:
      raiseAssert info & ": eff. peer arguments differ" &
        ", n=" & $n &
        ", serial=" & $instr.bag.serial &
        ", peer=" & $peer &
        ", peerID=" & $peerID &
        ", ethBlock=" & ethBlock.bnStr &
        # -----
        ", effPeerID=" & effPeerID.short &
        ", expected=" & instr.bag.effPeerID.short

    if ethBlock != instr.bag.ethBlock:
      raiseAssert info & ": block arguments differ" &
        ", n=" & $n &
        ", serial=" & $instr.bag.serial &
        ", peer=" & $peer &
        ", peerID=" & $peerID &
        ", effPeerID=" & effPeerID.short &
        # -----
        ", ethBlock=" & ethBlock.bnStr &
        ", expected=%" & instr.bag.ethBlock.bnStr &
        # -----
        ", ethBlock=%" & ethBlock.computeRlpHash.short &
        ", expected=%" & instr.bag.ethBlock.computeRlpHash.short
    data = instr

  let run = buddy.run
  if not run.fakeImport:
    let rc = await run.backup.importBlock(buddy, ethBlock, effPeerID)
    if rc.isErr or data.bag.error.isSome():
      const info = info & ": result values differ"
      let serial = data.bag.serial
      if rc.isErr and data.bag.error.isNone():
        warn info, n, serial, peer, peerID,
          got="err" & rc.error.toStr, expected="ok"
      elif rc.isOk and data.bag.error.isSome():
        warn info, n, serial, peer, peerID,
          got="ok", expected="err" & data.bag.error.value.toStr(true)
      elif rc.error.excp !=  data.bag.error.value.excp or
           rc.error.msg != data.bag.error.value.msg:
        warn info, n, serial, peer, peerID,
          got="err" & rc.error.toStr,
          expected="err" & data.bag.error.value.toStr(true)

  buddy.withInstr(ReplaySyncBlock, info):
    if not instr.isAvailable():
      return err(iError.getBeaconError()) # Shutdown?
    discard # no-op, visual alignment

  return data.getResponse()

# ------------------------------------------------------------------------------
# Public functions, data feed
# ------------------------------------------------------------------------------

proc sendBodies*(
    run: ReplayRunnerRef;
    instr: ReplayFetchBodies|ReplaySyncBodies;
      ) {.async: (raises: []).} =
  ## Stage bodies request/response data
  const info = instr.replayLabel()
  let buddy = run.getPeer(instr, info).valueOr:
    raiseAssert info & ": getPeer() failed" &
      ", n=" & $run.iNum &
      ", serial=" & $instr.bag.serial &
      ", peerID=" & instr.bag.peerCtx.value.peerID.short
  discard buddy.pushInstr(instr, info)

proc sendBlock*(
    run: ReplayRunnerRef;
    instr: ReplayImportBlock|ReplaySyncBlock;
      ) {.async: (raises: []).} =
  ## Stage block request/response data
  const info = instr.replayLabel()
  if instr.bag.peerCtx.isSome():
    # So it was captured run from a sync peer
    let buddy = run.getPeer(instr, info).valueOr:
      raiseAssert info & ": getPeer() failed" &
        ", n=" & $run.iNum &
        ", serial=" & $instr.bag.serial &
        ", peerID=" & instr.bag.peerCtx.value.peerID.short
    discard buddy.pushInstr(instr, info)

  # Verify that the daemon is properly initialised
  elif run.daemon.isNil:
    raiseAssert info & ": system error (no daemon)" &
      ", n=" & $run.iNum &
      ", serial=" & $instr.bag.serial &
      ", peer=n/a"

  else:
    discard run.daemon.pushInstr(instr, info)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
