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
  pkg/chronicles,
  pkg/eth/common,
  ../../../networking/p2p,
  ../../wire_protocol,
  ../worker_desc,
  ./blocks_staged/staged_queue,
  ./headers_staged/staged_queue,
  ./[blocks_unproc, headers_unproc]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc queryProgressCB(
    ctx: BeaconCtxRef;
    info: static[string];
      ): BeaconSyncerProgressCB =
  ## Syncer status query function/closure.
  return proc(): tuple[start, current, target: BlockNumber] =
    if not ctx.hibernate():
      return (ctx.layout.coupler,
              max(ctx.layout.coupler,
                  min(ctx.chain.latestNumber(), ctx.layout.head)),
              ctx.layout.head)
    # (0,0,0)

proc updateBeaconHeaderCB(
    ctx: BeaconCtxRef;
    info: static[string];
      ): ReqBeaconSyncerTargetCB =
  ## Update beacon header. This function is intended as a call back function
  ## for the RPC module.
  return proc(h: Header; f: Hash32) {.gcsafe, raises: [].} =

    # Check whether there is an update running (otherwise take next upate)
    if not ctx.clReq.locked and                   # can update ok
       f != zeroHash32 and                        # finalised hash is set
       ctx.layout.head < h.number and             # update is advancing
       ctx.clReq.mesg.consHead.number < h.number: # .. ditto

      ctx.clReq.mesg.consHead = h
      ctx.clReq.mesg.finalHash = f
      ctx.clReq.changed = true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc setupDatabase*(ctx: BeaconCtxRef; info: static[string]) =
  ## Initalise database related stuff

  # Initialise up queues and lists
  ctx.headersStagedQueueInit()
  ctx.blocksStagedQueueInit()
  ctx.headersUnprocInit()
  ctx.blocksUnprocInit()

  # Start in suspended mode
  ctx.hibernate = true

  # Set up header cache descriptor. This will evenually be integrated
  # into `ForkedChainRef` (i.e. `ctx.pool.chain`.)
  ctx.pool.hdrCache = ForkedCacheRef.init(ctx.pool.chain)

  # Initialise block queue size limit
  if ctx.pool.blkStagedWeightHwm < blocksStagedWeightLwm:
    ctx.pool.blkStagedWeightHwm = blocksStagedWeightHwmDefault


proc setupServices*(ctx: BeaconCtxRef; info: static[string]) =
  ## Helper for `setup()`: Enable external call-back based services
  # Activate `CL` requests. Will be called from RPC handler.
  ctx.pool.chain.com.reqBeaconSyncerTarget = ctx.updateBeaconHeaderCB info
  # Provide progress info
  ctx.pool.chain.com.beaconSyncerProgress = ctx.queryProgressCB info

proc destroyServices*(ctx: BeaconCtxRef) =
  ## Helper for `release()`
  ctx.pool.chain.com.reqBeaconSyncerTarget = ReqBeaconSyncerTargetCB(nil)
  ctx.pool.chain.com.beaconSyncerProgress = BeaconSyncerProgressCB(nil)

# ---------

proc startBuddy*(buddy: BeaconBuddyRef): bool =
  ## Convenience setting for starting a new worker
  let
    ctx = buddy.ctx
    peer = buddy.peer
  if peer.supports(wire_protocol.eth) and
     peer.state(wire_protocol.eth).initialized:
    ctx.pool.nBuddies.inc
    buddy.initHdrProcErrors()
    return true

proc stopBuddy*(buddy: BeaconBuddyRef) =
  let ctx = buddy.ctx
  ctx.pool.nBuddies.dec
  buddy.clearHdrProcErrors()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
