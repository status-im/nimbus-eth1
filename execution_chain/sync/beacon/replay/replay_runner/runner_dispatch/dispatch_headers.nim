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
  pkg/[chronicles, chronos, eth/common],
  ../../../../wire_protocol,
  ../../replay_desc,
  ./dispatch_helpers

logScope:
  topics = "replay runner"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc `==`(a,b: BlockHeadersRequest): bool =
  if a.maxResults == b.maxResults and
     a.skip == b.skip:
    if a.startBlock.isHash:
      if b.startBlock.isHash and
         a.startBlock.hash == b.startBlock.hash:
        return true
    else:
      if not b.startBlock.isHash and
         a.startBlock.number == b.startBlock.number:
        return true

func getResponse(
    instr: TraceGetBlockHeaders;
      ): Result[FetchHeadersData,BeaconError] =
  if (instr.fieldAvail and 1) != 0:
    ok(instr.fetched)
  else:
    err(instr.error)

func getBeaconError(e: ReplayWaitError): BeaconError =
  (e[0], e[1], e[2], Duration())

# ------------------------------------------------------------------------------
# Public dispatcher handlers
# ------------------------------------------------------------------------------

proc fetchHeadersHandler*(
    buddy: BeaconBuddyRef;
    req: BlockHeadersRequest;
      ): Future[Result[FetchHeadersData,BeaconError]]
      {.async: (raises: []).} =
  ## Replacement for `getBlockHeaders()` handler.
  const
    info = "&fetchHeaders: "
  let
    buddy = ReplayBuddyRef(buddy)
    instr = (await getSessionData[TraceGetBlockHeaders](buddy, info)).valueOr:
      return err(error.getBeaconError()) # Shutdown?

    serial = instr.serial                    # for logging
    peer = buddy.peer                        # for logging
    peerID = buddy.peerID.short              # for logging

  if req != instr.req:
    raiseAssert info & "arguments differ, serial=" & $serial &
      ", peer=" & $peer &
      # -----
      ", reverse=" & $req.reverse &
      ", expected=" & $instr.req.reverse &
      # -----
      ", reqStart=" & req.startBlock.toStr &
      ", expected=" & instr.req.startBlock.toStr &
      # -----
      ", reqLen=" & $req.maxResults &
      ", expected=" & $instr.req.maxResults

  trace info & "done", serial, peer, peerID
  return instr.getResponse()

# ------------------------------------------------------------------------------
# Public functions, data feed
# ------------------------------------------------------------------------------

proc fetchHeadersFeed*(
    run: ReplayRunnerRef;
    instr: TraceGetBlockHeaders;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Stage headers request/response data
  let buddy = run.getPeer(instr, info).expect "valid sync peer"
  (await buddy.provideSessionData(instr, info)).isOkOr:
    # some smart logging
    return

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
