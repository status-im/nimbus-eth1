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
  ../../../core/chain,
  ../worker_desc,
  ./blocks_staged/bodies,
  "."/[blocks_unproc, db, helpers, update]

# ------------------------------------------------------------------------------
# Private debugging & logging helpers
# ------------------------------------------------------------------------------

formatIt(Hash32):
  it.short

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func getNthHash(blk: BlocksForImport; n: int): Hash32 =
  if n + 1 < blk.blocks.len:
    blk.blocks[n + 1].header.parentHash
  else:
    rlp.encode(blk.blocks[n].header).keccak256


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
  var blockHash = newSeq[Hash32](ivReq.len)
  for n in 1u ..< ivReq.len:
    let header = ctx.dbHeaderPeek(ivReq.minPt + n).valueOr:
      # There is nothing one can do here
      info "Block header missing (reorg triggered)", ivReq, n,
        nth=(ivReq.minPt + n).bnStr
      # So require reorg
      blk.blocks.setLen(offset)
      ctx.poolMode = true
      return false
    blockHash[n - 1] = header.parentHash
    blk.blocks[offset + n].header = header
  blk.blocks[offset].header = ctx.dbHeaderPeek(ivReq.minPt).valueOr:
    # There is nothing one can do here
    info "Block header missing (reorg triggered)", ivReq, n=0,
      nth=ivReq.minPt.bnStr
    # So require reorg
    blk.blocks.setLen(offset)
    ctx.poolMode = true
    return false
  blockHash[ivReq.len - 1] =
    rlp.encode(blk.blocks[offset + ivReq.len - 1].header).keccak256

  # Fetch bodies
  let bodies = block:
    let rc = await buddy.bodiesFetch(blockHash, info)
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

      # Remove stashed header
      ctx.dbHeaderUnstash blk.blocks[offset + n].header.number

  if offset < blk.blocks.len.uint64:
    return true

  buddy.only.nBdyProcErrors.inc
  return false

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func blocksStagedCanImportOk*(ctx: BeaconCtxRef): bool =
  ## Check whether the queue is at its maximum size so import can start with
  ## a full queue.
  ##
  if ctx.poolMode:
    # Re-org is scheduled
    return false

  if 0 < ctx.blk.staged.len:
    # Import if what is on the queue is all we have got. Note that the function
    # `blocksUnprocIsEmpty()` returns `true` only if all blocks possible have
    # been fetched (i.e. the `borrowed` list is also empty.)
    if ctx.blocksUnprocIsEmpty():
      return true

    # Make sure that the lowest block is available, already. Or the other way
    # round: no unprocessed block number range precedes the least staged block.
    if ctx.blk.staged.ge(0).value.key < ctx.blocksUnprocTotalBottom():
      # Also suggest importing blocks if there is currently no peer active.
      # The `unprocessed` ranges will contain some higher number block ranges,
      # but these can be fetched later.
      if ctx.pool.nBuddies == 0:
        return true

      # Start importing if the queue is filled up enough
      if ctx.pool.stagedLenHwm <= ctx.blk.staged.len:
        return true

  false


func blocksStagedFetchOk*(ctx: BeaconCtxRef): bool =
  ## Check whether body records can be fetched and stored on the `staged` queue.
  ##
  if 0 < ctx.blocksUnprocAvail():
    # Fetch if there is space on the queue.
    if ctx.blk.staged.len < ctx.pool.stagedLenHwm:
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
  if buddy.ctx.blocksUnprocAvail() == 0:
    # Nothing to do
    return false

  let
    ctx = buddy.ctx
    peer = buddy.peer

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

  # nFetchBodiesRequest
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
        if ((0 < buddy.only.nBdyRespErrors or
             0 < buddy.only.nBdyProcErrors) and buddy.ctrl.stopped) or
           fetchBodiesReqErrThresholdCount < buddy.only.nBdyRespErrors or
           fetchBodiesProcessErrThresholdCount < buddy.only.nBdyProcErrors:
          # Make sure that this peer does not immediately reconnect
          buddy.ctrl.zombie = true

        trace info & ": current block list discarded", peer, iv, ivReq,
          nStaged=ctx.blk.staged.len, ctrl=buddy.ctrl.state,
          bdyErrors=buddy.bdyErrors

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

    # Update remaining interval
    let ivRespLen = blk.blocks.len - nBlkBlocks
    if iv.maxPt < ivBottom + ivRespLen.uint64:
      # All collected
      ctx.blocksUnprocCommit(iv)
      break

    ivBottom += ivRespLen.uint64 # will mostly result into `ivReq.maxPt+1`

    if buddy.ctrl.stopped:
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

  info "Downloaded blocks", bottomBlock=iv.minPt.bnStr,
    nBlocks=blk.blocks.len, nStaged=ctx.blk.staged.len,
    bdyErrors=buddy.bdyErrors

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
    trace info & ": block queue not ready yet", nBuddies=ctx.pool.nBuddies,
      unprocBottom=uBottom.bnStr, least=qItem.key.bnStr
    return false

  # Remove from queue
  discard ctx.blk.staged.delete qItem.key

  let
    nBlocks = qItem.data.blocks.len
    iv = BnRange.new(qItem.key, qItem.key + nBlocks.uint64 - 1)

  info "Importing blocks", iv, nBlocks,
    base=ctx.chain.baseNumber.bnStr, head=ctx.chain.latestNumber.bnStr,
    target=ctx.layout.final.bnStr

  var maxImport = iv.maxPt
  block importLoop:
    for n in 0 ..< nBlocks:
      let nBn = qItem.data.blocks[n].header.number
      if nBn <= ctx.chain.baseNumber:
        trace info & ": ignoring block less eq. base", n, iv,
          B=ctx.chain.baseNumber.bnStr, L=ctx.chain.latestNumber.bnStr,
          nthBn=nBn.bnStr, nthHash=qItem.data.getNthHash(n).short
        continue
      ctx.pool.chain.importBlock(qItem.data.blocks[n]).isOkOr:
        # The way out here is simply to re-compile the block queue. At any
        # point, the `FC` module data area might have been moved to a new
        # canonocal branch.
        #
        ctx.poolMode = true
        warn info & ": import block error (reorg triggered)", n, iv,
          B=ctx.chain.baseNumber.bnStr, L=ctx.chain.latestNumber.bnStr,
          nthBn=nBn.bnStr, nthHash=qItem.data.getNthHash(n).short,
          `error`=error
        break importLoop

      # Allow pseudo/async thread switch.
      (await ctx.updateAsyncTasks()).isOkOr:
        maxImport = nBn # shutdown?
        break importLoop

      # Occasionally mark the chain finalized
      if (n + 1) mod finaliserChainLengthMax == 0 or (n + 1) == nBlocks:
        let
          nthHash = qItem.data.getNthHash(n)
          finHash = if nBn < ctx.layout.final: nthHash
                    else: ctx.layout.finalHash

        doAssert nBn == ctx.chain.latestNumber()
        ctx.pool.chain.forkChoice(nthHash, finHash).isOkOr:
          warn info & ": fork choice error (reorg triggered)", n, iv,
            B=ctx.chain.baseNumber.bnStr, L=ctx.chain.latestNumber.bnStr,
            F=ctx.layout.final.bnStr, nthBn=nBn.bnStr, nthHash=nthHash.short,
            finHash=(if finHash == nthHash: "nthHash" else: "F"), `error`=error
          # Restore what is left over below
          ctx.poolMode = true
          break importLoop

        # Allow pseudo/async thread switch.
        (await ctx.updateAsyncTasks()).isOkOr:
          maxImport = nBn # shutdown?
          break importLoop

  # Import probably incomplete, so a partial roll back may be needed
  if maxImport < iv.maxPt:
    ctx.blocksUnprocAppend(maxImport+1, iv.maxPt)

  info "Import done", iv, nBlocks, base=ctx.chain.baseNumber.bnStr,
    head=ctx.chain.latestNumber.bnStr, target=ctx.layout.final.bnStr

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
  trace info & ": Flushing Block queues", nUnproc=ctx.blocksUnprocTotal(),
    nStaged=ctx.blk.staged.len

  ctx.blocksUnprocClear()
  ctx.blk.staged.clear()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
