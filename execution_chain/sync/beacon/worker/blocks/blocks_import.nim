# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/[chronicles, chronos, results],
  pkg/eth/common,
  ../../../wire_protocol,
  ../../worker_desc,
  ./blocks_helpers

logScope:
  topics = "beacon sync"

# ------------------------------------------------------------------------------
# Public handler
# ------------------------------------------------------------------------------

proc importCB*(
    ctx: BeaconCtxRef;
    maybePeer: Opt[BeaconBuddyRef];
    blk: EthBlock;
    effPeerID: Hash;
      ): Future[Result[Duration,BeaconError]]
      {.async: (raises: []).} =
  ## Wrapper around blocks importer
  let start = Moment.now()

  if blk.header.number <= ctx.chain.baseNumber:
    trace "Ignoring block less eq. base", peer=maybePeer.toStr, blk=blk.bnStr,
      B=ctx.chain.baseNumber.bnStr, L=ctx.chain.latestNumber.bnStr
  else:
    try:
      (await ctx.chain.queueImportBlock blk).isOkOr:
        return err((ENoException,"",error,Moment.now()-start))
    except CancelledError as e:
      return err((ECancelledError,$e.name,e.msg,Moment.now()-start))

  # Allow thread switch by issuing a short wait request. A minimum time
  # distance to the last task switch sleep request is maintained (see
  # `asyncThreadSwitchGap`.)
  if ctx.pool.nextAsyncNanoSleep < Moment.now():
    try:
      await sleepAsync asyncThreadSwitchTimeSlot
    except CancelledError as e:
      return err((ECancelledError,$e.name,e.msg,Moment.now()-start))

    if not ctx.daemon: # Daemon will be up unless shutdown
      return err((ENoException,"","syncer shutdown",Moment.now()-start))

    ctx.pool.nextAsyncNanoSleep = Moment.now() + asyncThreadSwitchGap

  return ok(Moment.now()-start)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

