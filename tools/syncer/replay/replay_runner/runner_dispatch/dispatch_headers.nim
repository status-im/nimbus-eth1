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
  ../../../../../execution_chain/sync/wire_protocol,
  ../runner_desc,
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
    instr: ReplayFetchHeaders;
      ): Result[FetchHeadersData,BeaconError] =
  if instr.bag.fetched.isSome():
    ok(instr.bag.fetched.value)
  elif instr.bag.error.isSome():
    err(instr.bag.error.value)
  else:
    err((ENoException,"","Missing fetch headers return code",Duration()))

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
  const info = "&fetchHeaders"
  let buddy = ReplayBuddyRef(buddy)

  var data: ReplayFetchHeaders
  buddy.withInstr(typeof data, info):
    if not instr.isAvailable():
      return err(iError.getBeaconError()) # Shutdown?
    if req != instr.bag.req:
      raiseAssert info & ": arguments differ" &
        ", n=" & $buddy.iNum &
        ", serial=" & $instr.bag.serial &
        ", peer=" & $buddy.peer &
        # -----
        ", reverse=" & $req.reverse &
        ", expected=" & $instr.bag.req.reverse &
        # -----
        ", reqStart=" & req.startBlock.toStr &
        ", expected=" & instr.bag.req.startBlock.toStr &
        # -----
        ", reqLen=" & $req.maxResults &
        ", expected=" & $instr.bag.req.maxResults
    data = instr

  buddy.withInstr(ReplaySyncHeaders, info):
    if not instr.isAvailable():
      return err(iError.getBeaconError()) # Shutdown?
    discard # no-op, visual alignment

  return data.getResponse()

# ------------------------------------------------------------------------------
# Public functions, data feed
# ------------------------------------------------------------------------------

proc sendHeaders*(
    run: ReplayRunnerRef;
    instr: ReplayFetchHeaders|ReplaySyncHeaders;
      ) {.async: (raises: []).} =
  ## Stage headers request/response data
  const info = instr.replayLabel()
  let buddy = run.getPeer(instr, info).valueOr:
    raiseAssert info & ": getPeer() failed" &
      ", n=" & $run.iNum &
      ", serial=" & $instr.bag.serial
  discard buddy.pushInstr(instr, info)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
