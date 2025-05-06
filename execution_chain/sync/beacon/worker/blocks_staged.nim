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
  pkg/[chronicles, chronos],
  pkg/eth/common,
  pkg/stew/[interval_set, sorted_set],
  ../worker_desc,
  ./blocks_staged/[bodies, staged_blocks],
  ../../wire_protocol/types,
  ./[blocks_unproc, helpers]

# ------------------------------------------------------------------------------
# Private debugging & logging helpers
# ------------------------------------------------------------------------------

formatIt(Hash32):
  it.short

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc updateBuddyErrorState(buddy: BeaconBuddyRef) =
  ## Helper/wrapper
  if ((0 < buddy.only.nBdyRespErrors or
       0 < buddy.only.nBdyProcErrors) and buddy.ctrl.stopped) or
     fetchBodiesReqErrThresholdCount < buddy.only.nBdyRespErrors or
     fetchBodiesProcessErrThresholdCount < buddy.only.nBdyProcErrors:

    # Make sure that this peer does not immediately reconnect
    buddy.ctrl.zombie = true

# ------------------------------------------------------------------------------
# Private function(s)
# ------------------------------------------------------------------------------

proc fetchAndCheck(
    buddy: BeaconBuddyRef;
    ivReq: BnRange;
    blk: ref BlocksForImport; # update in place
    info: static[string];
      ): Future[bool] {.async: (raises: []).} =

  let
    ctx = buddy.ctx
    offset = blk.blocks.len.uint64

  # Make sure that the block range matches the top
  doAssert offset == 0 or blk.blocks[offset - 1].header.number+1 == ivReq.minPt

  # Preset/append headers to be completed with bodies. Also collect block hashes
  # for fetching missing blocks.
  blk.blocks.setLen(offset + ivReq.len)
  var request = BlockBodiesRequest(
    blockHashes: newSeq[Hash32](ivReq.len)
  )
  for n in 1u ..< ivReq.len:
    let header = ctx.hdrCache.get(ivReq.minPt + n).valueOr:
      # There is nothing one can do here
      info "Block header missing (reorg triggered)", ivReq, n,
        nth=(ivReq.minPt + n).bnStr
      # So require reorg
      blk.blocks.setLen(offset)
      ctx.poolMode = true
      return false
    request.blockHashes[n - 1] = header.parentHash
    blk.blocks[offset + n].header = header
  blk.blocks[offset].header = ctx.hdrCache.get(ivReq.minPt).valueOr:
    # There is nothing one can do here
    info "Block header missing (reorg triggered)", ivReq, n=0,
      nth=ivReq.minPt.bnStr
    # So require reorg
    blk.blocks.setLen(offset)
    ctx.poolMode = true
    return false
  request.blockHashes[ivReq.len - 1] =
    blk.blocks[offset + ivReq.len - 1].header.computeBlockHash

  # Fetch bodies
  let bodies = block:
    let rc = await buddy.bodiesFetch(request, info)
    if rc.isErr:
      blk.blocks.setLen(offset)
      return false
    rc.value

  # Append bodies, note that the bodies are not fully verified here but rather
  # when they are imported and executed.
  let nBodies = bodies.len.uint64
  if nBodies < ivReq.len:
    blk.blocks.setLen(offset + nBodies)
  block loop:
    for n in 0 ..< nBodies:
      block checkTxLenOk:
        if blk.blocks[offset + n].header.transactionsRoot != emptyRoot:
          if 0 < bodies[n].transactions.len:
            break checkTxLenOk
        else:
          if bodies[n].transactions.len == 0:
            break checkTxLenOk
        # Oops, cut off the rest
        blk.blocks.setLen(offset + n)
        buddy.fetchRegisterError()
        trace info & ": cut off fetched junk", peer=buddy.peer, ivReq, n,
          nTxs=bodies[n].transactions.len, nBodies, bdyErrors=buddy.bdyErrors
        break loop

      blk.blocks[offset + n].transactions = bodies[n].transactions
      blk.blocks[offset + n].uncles       = bodies[n].uncles
      blk.blocks[offset + n].withdrawals  = bodies[n].withdrawals

  if offset < blk.blocks.len.uint64:
    return true

  buddy.only.nBdyProcErrors.inc
  return false

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc blocksStagedCanImportOk*(ctx: BeaconCtxRef; info: static[string]): bool =
  ## Check whether the queue is at its maximum size so import can start with
  ## a full queue.
  ##
  if ctx.poolMode:
    # Re-org is scheduled
    return false

  if 0 < ctx.blk.staged.len:
    # Start importing if there are no more blocks available. So they have
    # either been all staged, or are about to be staged. For the latter
    # case wait until finished with current block downloads.
    if ctx.blocksUnprocAvail() == 0:

      # Wait until finished with current block downloads
      return ctx.blocksBorrowedIsEmpty()

    # Make sure that the lowest block is available, already. Or the other way
    # round: no unprocessed block number range precedes the least staged block.
    if ctx.blk.staged.ge(0).value.key < ctx.blocksUnprocTotalBottom():
      # Also suggest importing blocks if there is currently no peer active.
      # The `unprocessed` ranges will contain some higher number block ranges,
      # but these can be fetched later.
      if ctx.pool.nBuddies == 0:
        return true

      # If the last peer is labelled `slow` it will be ignored for the sake
      # of deciding whether to execute blocks.
      #
      # As a consequence, the syncer will import blocks immediately allowing
      # the syncer to collect more sync peers.
      if ctx.pool.nBuddies == 1 and ctx.pool.blkLastSlowPeer.isSome:
        trace info & ": last slow peer",
          peerID=ctx.pool.blkLastSlowPeer.value, nSyncPeers=ctx.pool.nBuddies
        return true

      # Importing does not start before the queue is filled up.
      if blocksStagedQueueLengthHwm <= ctx.blk.staged.len:
        return ctx.blocksBorrowedIsEmpty()

  false


func blocksStagedFetchOk*(buddy: BeaconBuddyRef): bool =
  ## Check whether body records can be fetched and stored on the `staged` queue.
  ##
  if buddy.ctrl.running:

    let ctx = buddy.ctx
    if not ctx.poolMode:

      if 0 < ctx.blocksUnprocAvail():
        # Fetch if there is space on the queue.
        if ctx.blk.staged.len < blocksStagedQueueLengthHwm:
          return true

        # Make sure that there is no gap at the bottom which needs to be
        # fetched regardless of the length of the queue.
        if ctx.blocksUnprocAvailBottom() < ctx.blk.staged.ge(0).value.key:
          return true
  false



proc blocksStagedCollect*(
    buddy: BeaconBuddyRef;
    info: static[string];
      ): Future[bool] {.async: (raises: []).} =
  ## Collect bodies and stage them.
  ##
  let
    ctx = buddy.ctx
    peer = buddy.peer

  if ctx.blocksUnprocAvail() == 0 or                   # all done already?
     ctx.poolMode:                                     # reorg mode?
    return false                                       # nothing to do

  let
    # Fetch the full range of headers to be completed to blocks
    iv = ctx.blocksUnprocFetch(nFetchBodiesBatch.uint64).expect "valid interval"

  var
    # This value is used for splitting the interval `iv` into
    # `already-collected + [ivBottom,somePt] + [somePt+1,iv.maxPt]` where the
    # middle interval `[ivBottom,somePt]` will be fetched from the network.
    ivBottom = iv.minPt

    # This record will accumulate the fetched headers. It must be on the heap
    # so that `async` can capture that properly.
    blk = (ref BlocksForImport)()

    # Flag, not to reset error count
    haveError = false

  while true:
    # Extract bottom range interval and fetch/stage it
    let
      ivReqMax = if iv.maxPt < ivBottom + nFetchBodiesRequest - 1: iv.maxPt
                 else: ivBottom + nFetchBodiesRequest - 1

      # Request interval
      ivReq = BnRange.new(ivBottom, ivReqMax)

      # Current length of the blocks queue. This is used to calculate the
      # response length from the network.
      nBlkBlocks = blk.blocks.len

    # Fetch and extend staging record
    if not await buddy.fetchAndCheck(ivReq, blk, info):
      if ctx.poolMode:
        # Reorg requested?
        ctx.blocksUnprocCommit(iv, iv)
        return false

      haveError = true

      # Throw away first time block fetch data. Keep other data for a
      # partially assembled list.
      if nBlkBlocks == 0:
        buddy.updateBuddyErrorState()

        if ctx.pool.seenData:
          trace info & ": current blocks discarded", peer, iv, ivReq,
            nStaged=ctx.blk.staged.len, ctrl=buddy.ctrl.state,
            bdyErrors=buddy.bdyErrors
        else:
          # Collect peer for detecting cul-de-sac syncing (i.e. non-existing
          # block chain or similar.) This covers the case when headers are
          # available but not block bodies.
          ctx.pool.failedPeers.incl buddy.peerID

          debug info & ": no blocks yet", peer, ctrl=buddy.ctrl.state,
            failedPeers=ctx.pool.failedPeers.len, bdyErrors=buddy.bdyErrors

        ctx.blocksUnprocCommit(iv, iv)
        # At this stage allow a task switch so that some other peer might try
        # to work on the currently returned interval.
        try: await sleepAsync asyncThreadSwitchTimeSlot
        except CancelledError: discard
        return false

      # So there were some bodies downloaded already. Turn back unused data
      # and proceed with staging.
      trace info & ": list partially failed", peer, iv, ivReq,
        unused=BnRange.new(ivBottom,iv.maxPt)
      # There is some left over to store back
      ctx.blocksUnprocCommit(iv, ivBottom, iv.maxPt)
      break

    # There are block body data for this scrum
    ctx.pool.seenData = true

    # Update remaining interval
    let ivRespLen = blk.blocks.len - nBlkBlocks
    if iv.maxPt < ivBottom + ivRespLen.uint64:
      # All collected
      ctx.blocksUnprocCommit(iv)
      break

    ivBottom += ivRespLen.uint64 # will mostly result into `ivReq.maxPt+1`

    if buddy.ctrl.stopped or ctx.poolMode:
      # There is some left over to store back. And `ivBottom <= iv.maxPt`
      # because of the check against `ivRespLen` above.
      ctx.blocksUnprocCommit(iv, ivBottom, iv.maxPt)
      break

  # Store `blk` chain on the `staged` queue
  let qItem = ctx.blk.staged.insert(iv.minPt).valueOr:
    raiseAssert info & ": duplicate key on staged queue iv=" & $iv
  qItem.data = blk[]

  # Reset block process errors (not too many consecutive failures this time)
  if not haveError:
    buddy.only.nBdyProcErrors = 0

  info "Downloaded blocks", iv=blk.blocks.bnStr,
    nBlocks=blk.blocks.len, nStaged=ctx.blk.staged.len,
    nSyncPeers=ctx.pool.nBuddies

  return true


proc blocksStagedImport*(
    ctx: BeaconCtxRef;
    info: static[string];
      ): Future[bool]
      {.async: (raises: []).} =
  ## Import/execute blocks record from staged queue
  ##
  let qItem = ctx.blk.staged.ge(0).valueOr:
    # Empty queue
    return false

  # Make sure that the lowest block is available, already. Or the other way
  # round: no unprocessed block number range precedes the least staged block.
  let uBottom = ctx.blocksUnprocTotalBottom()
  if uBottom < qItem.key:
    trace info & ": block queue not ready yet", nSyncPeers=ctx.pool.nBuddies,
      unprocBottom=uBottom.bnStr, least=qItem.key.bnStr
    return false

  # Remove from queue
  discard ctx.blk.staged.delete qItem.key

  await ctx.blocksImport(qItem.data.blocks, info)

  # Import probably incomplete, so a partial roll back may be needed
  let lastBn = qItem.data.blocks[^1].header.number
  if ctx.blk.topImported < lastBn:
    ctx.blocksUnprocAppend(ctx.blk.topImported+1, lastBn)

  return true



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
    nStaged=ctx.blk.staged.len, nReorg=ctx.pool.nReorg

  ctx.blocksUnprocClear()
  ctx.blk.staged.clear()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
