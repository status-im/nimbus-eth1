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
  ../../../../wire_protocol,
  ../../[trace_desc, trace_write],
  ./helpers

logScope:
  topics = "beacon trace"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetchHeadersTrace*(
    buddy: BeaconBuddyRef;
    req: BlockHeadersRequest;
      ): Future[Result[FetchHeadersData,BeaconError]]
      {.async: (raises: []).} =
  ## Replacement for `getBlockHeaders()` handler which in addition writes data
  ## to the output stream for tracing.
  ##
  let data = await buddy.ctx.trace.backup.getBlockHeaders(buddy, req)

  var tRec: TraceFetchHeaders
  tRec.init buddy
  tRec.req = req
  if data.isOk:
    tRec.fieldAvail = 1
    tRec.fetched = data.value
  else:
    tRec.fieldAvail = 2
    tRec.error = data.error
  buddy.traceWrite tRec

  trace "=HeadersFetch", peer=($buddy.peer), peerID=buddy.peerID.short,
    serial=tRec.serial
  return data

proc syncHeadersTrace*(
    buddy: BeaconBuddyRef;
      ) =
  ## Replacement for `syncBlockHeaders()` handler,
  ##
  var tRec: TraceSyncHeaders
  tRec.init buddy
  buddy.traceWrite tRec

  trace "=HeadersSync", peer=($buddy.peer), peerID=buddy.peerID.short,
    serial=tRec.serial

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
