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
  pkg/stew/[interval_set, sorted_set],
  ../../../networking/p2p,
  ../worker_desc,
  ./blocks_staged/[bodies, staged_blocks],
  ./[blocks_unproc, helpers]

# ------------------------------------------------------------------------------
# Private function(s)
# ------------------------------------------------------------------------------

proc blocksStagedProcessImpl(
    ctx: BeaconCtxRef;
    maybePeer: Opt[Peer];
    info: static[string];
      ): Future[bool]
      {.async: (raises: []).} =
  ## Import/execute blocks record from staged queue.
  ##
  ## The function returns `false` if the caller should make sure to allow
  ## to switch to another sync peer, e.g. for directly filling the gap
  ## between the top of the `topImported` and the least queue block number.
  ##
  if ctx.blk.staged.len == 0:
    trace info & ": blocksStagedProcess empty queue", peer=($maybePeer),
      topImported=ctx.blk.topImported.bnStr, nStagedQ=ctx.blk.staged.len,
      poolMode=ctx.poolMode, syncState=ctx.pool.lastState,
      nSyncPeers=ctx.pool.nBuddies
    return false                                             # switch peer

  var
    nImported = 0u64                                         # statistics
    switchPeer = false                                       # for return code

  trace info & ": blocksStagedProcess start", peer=($maybePeer),
    topImported=ctx.blk.topImported.bnStr, nStagedQ=ctx.blk.staged.len,
    poolMode=ctx.poolMode, syncState=ctx.pool.lastState,
    nSyncPeers=ctx.pool.nBuddies

  var minNum = BlockNumber(0)
  while ctx.pool.lastState == processingBlocks:

    # Fetch list with the least block numbers
    let qItem = ctx.blk.staged.ge(0).valueOr:
      break                                                  # all done

    # Make sure that the lowest block is available, already. Or the other way
    # round: no unprocessed block number range precedes the least staged block.
    minNum = qItem.data.blocks[0].header.number
    if ctx.blk.topImported + 1 < minNum:
      trace info & ": block queue not ready yet", peer=($maybePeer),
        topImported=ctx.blk.topImported.bnStr, qItem=qItem.data.blocks.bnStr,
        nStagedQ=ctx.blk.staged.len, nSyncPeers=ctx.pool.nBuddies
      switchPeer = true # there is a gap -- come back later
      break

    # Remove from queue
    discard ctx.blk.staged.delete qItem.key

    # Import blocks list
    await ctx.blocksImport(maybePeer, qItem.data.blocks, info)

    # Import probably incomplete, so a partial roll back may be needed
    let lastBn = qItem.data.blocks[^1].header.number
    if ctx.blk.topImported < lastBn:
      ctx.blocksUnprocAppend(ctx.blk.topImported+1, lastBn)

    nImported += ctx.blk.topImported - minNum + 1
    # End while loop

  if 0 < nImported:
    info "Blocks serialised and imported",
      topImported=ctx.blk.topImported.bnStr, nImported,
      nStagedQ=ctx.blk.staged.len, nSyncPeers=ctx.pool.nBuddies, switchPeer

  elif 0 < ctx.blk.staged.len and not switchPeer:
    trace info & ": no blocks unqueued", peer=($maybePeer),
      topImported=ctx.blk.topImported.bnStr, nStagedQ=ctx.blk.staged.len,
      nSyncPeers=ctx.pool.nBuddies

  trace info & ": blocksStagedProcess end", peer=($maybePeer),
    topImported=ctx.blk.topImported.bnStr, nImported, minNum,
    nStagedQ=ctx.blk.staged.len, nSyncPeers=ctx.pool.nBuddies, switchPeer

  return not switchPeer

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func blocksStagedCollectOk*(buddy: BeaconBuddyRef): bool =
  ## Check whether body records can be fetched and imported or stored
  ## on the `staged` queue.
  ##
  if buddy.ctrl.running:
    let ctx = buddy.ctx
    if 0 < ctx.blocksUnprocAvail() and
       not ctx.blocksModeStopped():
      return true
  false

proc blocksStagedProcessOk*(ctx: BeaconCtxRef): bool =
  ## Check whether import processing is possible
  ##
  not ctx.poolMode and
  0 < ctx.blk.staged.len

# --------------

proc blocksStagedCollect*(
    buddy: BeaconBuddyRef;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Collect bodies and import or stage them.
  ##
  let
    ctx = buddy.ctx
    peer = buddy.peer

  if ctx.blocksUnprocIsEmpty():
    return                                           # no action

  var
    nImported = 0u64                                 # statistics, to be updated
    nQueued = 0                                      # ditto

  block fetchBlocksBody:
    #
    # Start deterministically. Explicitely fetch/append by parent hash.
    #
    # Exactly one peer can fetch and import store blocks directly on the `FC`
    # module. All other peers fetch and queue blocks for later serialisation.
    while true:
      let bottom = ctx.blocksUnprocAvailBottom() - 1
      #
      # A direct fetch and blocks import is possible if the next block to
      # fetch neigbours the already imported blocks ening at `lastImported`.
      # So this criteria is unique at a given time and when an interval is
      # taken out of the `unproc` pool:
      # ::
      #               |------------------      unproc pool
      #               |-------|                block interval to fetch next
      #    ----------|                         already imported into `FC` module
      #            bottom
      #         topImported
      #
      # After claiming the block interval that will be processed next for the
      # deterministic fetch, the situation for the new `bottom` would look like
      # ::
      #                        |---------      unproc pool
      #               |-------|                block interval to fetch next
      #    ----------|                         already imported into `FC` module
      #         topImported bottom
      #
      if ctx.blk.topImported < bottom:
        break

      # Throw away overlap (should not happen anyway)
      if bottom < ctx.blk.topImported:
        discard ctx.blocksUnprocFetch(ctx.blk.topImported - bottom).expect("iv")

      trace info & ": blocksStagedCollect direct loop", peer,
        ctrl=buddy.ctrl.state, poolMode=ctx.poolMode,
        syncState=ctx.pool.lastState, topImported=ctx.blk.topImported.bnStr,
        bottom=bottom.bnStr

      # Fetch blocks and verify result
      let blocks = (await buddy.blocksFetch(nFetchBodiesRequest, info)).valueOr:
        break fetchBlocksBody                        # done, exit this function

      # Set flag that there were some blocks fetched at all
      ctx.pool.seenData = true                       # blocks data exist

      # Import blocks (no staging)
      await ctx.blocksImport(Opt.some(peer), blocks, info)

      # Import probably incomplete, so a partial roll back may be needed
      let lastBn = blocks[^1].header.number
      if ctx.blk.topImported < lastBn:
        ctx.blocksUnprocAppend(ctx.blk.topImported + 1, lastBn)

      # statistics
      nImported += ctx.blk.topImported - blocks[0].header.number + 1

      # Buddy might have been cancelled while importing blocks.
      if buddy.ctrl.stopped or ctx.poolMode:
        break fetchBlocksBody                        # done, exit this function

      # End while: headersUnprocFetch() + blocksImport()

    # Continue fetching blocks and queue them (if any)
    if ctx.blk.staged.len + ctx.blk.reserveStaged < blocksStagedQueueLengthHwm:

      # Fetch blocks and verify result
      ctx.blk.reserveStaged.inc                     # Book a slot on `staged`
      let rc = await buddy.blocksFetch(nFetchBodiesRequest, info)
      ctx.blk.reserveStaged.dec                     # Free that slot again

      if rc.isErr:
        break fetchBlocksBody                     # done, exit this function

      let
        blocks = rc.value

        # Insert blocks list on the `staged` queue
        key = blocks[0].header.number
        qItem = ctx.blk.staged.insert(key).valueOr:
          raiseAssert info & ": duplicate key on staged queue iv=" &
            (key, blocks[^1].header.number).bnStr

      qItem.data.blocks = blocks                    # store `blocks[]` list

      nQueued += blocks.len                         # statistics

    # End block: `fetchBlocksBody`

  if nImported == 0 and nQueued == 0:
    if not ctx.pool.seenData and
       buddy.peerID notin ctx.pool.failedPeers and
       buddy.ctrl.stopped:
      # Collect peer for detecting cul-de-sac syncing (i.e. non-existing
      # block chain or similar.)
      ctx.pool.failedPeers.incl buddy.peerID

      debug info & ": no blocks yet", peer, ctrl=buddy.ctrl.state,
        poolMode=ctx.poolMode, syncState=ctx.pool.lastState,
        failedPeers=ctx.pool.failedPeers.len, bdyErrors=buddy.bdyErrors
    return

  info "Queued/staged or imported blocks",
    topImported=ctx.blk.topImported.bnStr,
    unprocBottom=(if ctx.blocksModeStopped(): "n/a"
                  else: ctx.blocksUnprocAvailBottom.bnStr),
    nQueued, nImported, nStagedQ=ctx.blk.staged.len,
    nSyncPeers=ctx.pool.nBuddies


template blocksStagedProcess*(
    ctx: BeaconCtxRef;
    info: static[string];
      ): auto =
  ctx.blocksStagedProcessImpl(Opt.none(Peer), info)

template blocksStagedProcess*(
    buddy: BeaconBuddyRef;
    info: static[string];
      ): auto =
  buddy.ctx.blocksStagedProcessImpl(Opt.some(buddy.peer), info)


proc blocksStagedReorg*(ctx: BeaconCtxRef; info: static[string]) =
  ## Some pool mode intervention.
  ##
  ## One scenario is that some blocks do not have a matching header available.
  ## The main reson might be that the queue of block lists had a gap so that
  ## some blocks could not be imported. This in turn can happen when the `FC`
  ## module was reset (e.g. by `CL` via RPC.)
  ##
  ## A reset by `CL` via RPC would mostly happen if the syncer is near the
  ## top of the block chain anyway. So the savest way to re-org is to flush
  ## the block queues as there won't be mant data cached, then.
  ##
  if ctx.blk.staged.len == 0 and
     ctx.blocksUnprocIsEmpty():
    # nothing to do
    return

  # Update counter
  ctx.pool.nReorg.inc

  # Reset block queues
  debug info & ": Flushing block queues", nUnproc=ctx.blocksUnprocTotal(),
    nStagedQ=ctx.blk.staged.len, nReorg=ctx.pool.nReorg

  ctx.blocksUnprocClear()
  ctx.blk.staged.clear()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
