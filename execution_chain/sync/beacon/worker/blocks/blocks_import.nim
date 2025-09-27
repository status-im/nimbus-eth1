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
  ../worker_desc

# ------------------------------------------------------------------------------
# Public function
# ------------------------------------------------------------------------------

proc importBlock*(
    buddy: BeaconBuddyRef;
    blk: EthBlock;
    effPeerID: Hash;
      ): Future[Result[Duration,BeaconError]]
      {.async: (raises: []).} =
  ## Wrapper around blocks importer
  let
    start = Moment.now()
    ctx = buddy.ctx
    peer = buddy.peer

  if blk.header.number <= ctx.chain.baseNumber:
    trace "Ignoring block less eq. base", peer, blk=blk.bnStr,
      B=ctx.chain.baseNumber.bnStr, L=ctx.chain.latestNumber.bnStr
  else:
    try:
      # At this point the header chain has already been verifed and so we know
      # the block is finalized as long as the block number is less than or equal
      # to the latest finalized block. Setting the finalized flag to true here
      # has the effect of skipping the stateroot check for performance reasons.
      let isFinalized = blk.header.number <= ctx.chain.latestFinalizedBlockNumber
      (await ctx.chain.queueImportBlock(blk, isFinalized)).isOkOr:
        return err((ENoException, "", error, Moment.now() - start))
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
