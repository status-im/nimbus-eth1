# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
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

logScope:
  topics = "beacon sync"

# ------------------------------------------------------------------------------
# Public handler
# ------------------------------------------------------------------------------

proc importBlockCB*(
    buddy: BeaconPeerRef;
    blk: EthBlock;
    effPeerID: Hash;
      ): Future[Result[Duration,BeaconError]]
      {.async: (raises: []).} =
  ## Wrapper around blocks importer
  let
    start = Moment.now()
    ctx = buddy.ctx
    peer {.inject,used.} = $buddy.peer              # logging only

  if blk.header.number <= ctx.chain.baseNumber:
    trace "Ignoring block less eq. base", peer, blk=blk.header.number,
      B=ctx.chain.baseNumber, L=ctx.chain.latestNumber
  else:
    try:
      # TODO: The block access list needs to be passed in when available over devp2p
      # and when the block falls within the BAL retention period.
      (await ctx.chain.queueImportBlock(blk, Opt.none(BlockAccessListRef))).isOkOr:
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
      return err((ESyncerTermination,"","",Moment.now()-start))

    ctx.pool.nextAsyncNanoSleep = Moment.now() + asyncThreadSwitchGap

  return ok(Moment.now()-start)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
