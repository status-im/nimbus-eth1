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

# ----------------
  
func getResponse(
    instr: TraceGetBlockBodies;
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
    instr = (await getSessionData[TraceImportBlock](desc, info)).valueOr:
      return err(error.getBeaconError()) # Shutdown?

    serial = instr.serial                    # for logging

  when desc is ReplayBuddyRef:
    let peer = desc.peer
    let peerID = desc.peerID.short
  else:
    let peer = "n/a"
    let peerID = "n/a"

  if effPeerID != instr.peerID or
     ethBlock != instr.ethBlock:
    raiseAssert info & "arguments differ, serial=" & $serial &
      ", peer=" & $peer &
      # -----
      ", effPeerID=" & effPeerID.short &
      ", expected=" & instr.effPeerID.short &
      # -----
      ", ethBlock=%" & ethBlock.computeRlpHash.short &
      ", expected=%" & instr.ethBlock.computeRlpHash.short

  trace info & "done", serial, peer, peerID
  return instr.getResponse()


proc importBlockFeedImpl(
    desc: ReplayDaemonRef|ReplayBuddyRef;
    instr: TraceImportBlock;
    info: static[string];
      ) {.async: (raises: []).} =
  (await desc.provideSessionData(instr, info)).isOkOr:
    # some smart logging
    return

# ------------------------------------------------------------------------------
# Public dispatcher handlers
# ------------------------------------------------------------------------------

proc fetchBodiesHandler*(
    buddy: BeaconBuddyRef;
    req: BlockBodiesRequest;
      ): Future[Result[FetchBodiesData,BeaconError]]
      {.async: (raises: []).} =
  const info = "&fetchBodies: "

  let
    buddy = ReplayBuddyRef(buddy)
    instr = (await getSessionData[TraceGetBlockBodies](buddy, info)).valueOr:
      return err(error.getBeaconError()) # Shutdown?

    serial = instr.serial                    # for logging
    peer = buddy.peer                        # for logging

  if req != instr.req:
    raiseAssert info & "arguments differ, serial=" & $serial &
      ", peer=" & $peer &
      # -----
      ", nBlockHashes=" & $req.blockHashes.len &
      ", expected=" & $instr.ivReq.len &
      # -----
      ", blockHashes=" & req.blockHashes.bnStr(buddy, info)  &
      ", expected=" & instr.ivReq.bnStr

  trace info & "done", serial, peer, peerID=buddy.peerID.short
  return instr.getResponse()


proc importBlockHandler*(
    ctx: BeaconCtxRef;
    maybePeer: Opt[BeaconBuddyRef];
    ethBlock: EthBlock;
    effPeerID: Hash;
      ): Future[Result[Duration,BeaconError]]
      {.async: (raises: []).} =
  ## Replacement for `importBlock()` handler.
  const info = "importBlock: "

  if maybePeer.isSome():
    let buddy = ReplayBuddyRef(maybePeer.value)
    return await buddy.importBlockHandlerImpl(ethBlock, effPeerID, info)

  # Verify that the daemon is properly initialised
  let
    run = ctx.replay.runner
    daemon = run.daemon
  if daemon.isNil:
    raiseAssert info & "system error (no daemon), serial=" &
      ", peer=n/a" & ", effPeerID=" & effPeerID.short

  return await daemon.importBlockHandlerImpl(ethBlock, effPeerID, info)
 
# ------------------------------------------------------------------------------
# Public functions, data feed
# ------------------------------------------------------------------------------

proc fetchBodiesFeed*(
    run: ReplayRunnerRef;
    instr: TraceGetBlockBodies;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Stage bodies request/response data
  let buddy = run.getPeer(instr, info).expect "valid sync peer"

  (await buddy.provideSessionData(instr, info)).isOkOr:
    # some smart logging
    return


proc importBlockFeed*(
    run: ReplayRunnerRef;
    instr: TraceImportBlock;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Stage block request/response data
  if (instr.stateAvail and 2) != 0:
    # So it was captured run from a sync peer
    let buddy = run.getPeer(instr, info).expect "valid sync peer"

    await buddy.importBlockFeedImpl(instr, info)

  # Verify that the daemon is properly initialised
  elif run.daemon.isNil:
    raiseAssert info & "system error (no daemon), serial=" & $instr.serial &
      ", peer=n/a" & ", effPeerID=" & instr.effPeerID.short

  else:
    await run.daemon.importBlockFeedImpl(instr, info)

  # ---------------------------------------------------
  # trace info & "done this time -- STOP", serial=instr.serial
  # quit(QuitSuccess) # ********** DEBUG *************
  # ---------------------------------------------------

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
