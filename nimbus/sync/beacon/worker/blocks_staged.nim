# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  ./update/metrics,
  "."/[blocks_unproc, db, helpers]

# ------------------------------------------------------------------------------
# Private debugging & logging helpers
# ------------------------------------------------------------------------------

formatIt(Hash32):
  it.data.short

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
      ): Future[bool] {.async.} =

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
    let header = ctx.dbPeekHeader(ivReq.minPt + n).valueOr:
      # There is nothing one can do here
      raiseAssert info & " stashed header missing: n=" & $n &
        " ivReq=" & $ivReq & " nth=" & (ivReq.minPt + n).bnStr
    blockHash[n - 1] = header.parentHash
    blk.blocks[offset + n].header = header
  blk.blocks[offset].header = ctx.dbPeekHeader(ivReq.minPt).valueOr:
    # There is nothing one can do here
    raiseAssert info & " stashed header missing: n=0" &
      " ivReq=" & $ivReq & " nth=" & ivReq.minPt.bnStr
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
        trace info & ": fetch bodies cut off junk", peer=buddy.peer, ivReq,
          n, nTxs=bodies[n].transactions.len, nBodies,
          nRespErrors=buddy.only.nBdyRespErrors
        break loop

      blk.blocks[offset + n].transactions = bodies[n].transactions
      blk.blocks[offset + n].uncles       = bodies[n].uncles
      blk.blocks[offset + n].withdrawals  = bodies[n].withdrawals

  return offset < blk.blocks.len.uint64

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func blocksStagedCanImportOk*(ctx: BeaconCtxRef): bool =
  ## Check whether the queue is at its maximum size so import can start with
  ## a full queue.
  if ctx.pool.blocksStagedQuLenMax <= ctx.blk.staged.len:
    return true

  if 0 < ctx.blk.staged.len:
    # Import if what is on the queue is all we have got.
    if ctx.blocksUnprocIsEmpty() and ctx.blocksUnprocBorrowed() == 0:
      return true
    # Import if there is currently no peer active
    if ctx.pool.nBuddies == 0:
      return true

  false


func blocksStagedFetchOk*(ctx: BeaconCtxRef): bool =
  ## Check whether body records can be fetched and stored on the `staged` queue.
  ##
  let uBottom = ctx.blocksUnprocBottom()
  if uBottom < high(BlockNumber):
    # Not to start fetching while the queue is busy (i.e. larger than Lwm)
    # so that import might still be running strong.
    if ctx.blk.staged.len < ctx.pool.blocksStagedQuLenMax:
      return true

    # Make sure that there is no gap at the bottom which needs to be
    # addressed regardless of the length of the queue.
    if uBottom < ctx.blk.staged.ge(0).value.key:
      return true

  false


proc blocksStagedCollect*(
    buddy: BeaconBuddyRef;
    info: static[string];
      ): Future[bool] {.async.} =
  ## Collect bodies and stage them.
  ##
  if buddy.ctx.blocksUnprocIsEmpty():
    # Nothing to do
    return false

  let
    ctx = buddy.ctx
    peer = buddy.peer

    # Fetch the full range of headers to be completed to blocks
    iv = ctx.blocksUnprocFetch(
      ctx.pool.nBodiesBatch.uint64).expect "valid interval"

  var
    # This value is used for splitting the interval `iv` into
    # `already-collected + [ivBottom,somePt] + [somePt+1,iv.maxPt]` where the
    # middle interval `[ivBottom,somePt]` will be fetched from the network.
    ivBottom = iv.minPt

    # This record will accumulate the fetched headers. It must be on the heap
    # so that `async` can capture that properly.
    blk = (ref BlocksForImport)()

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

      # Throw away first time block fetch data. Keep other data for a
      # partially assembled list.
      if nBlkBlocks == 0:
        buddy.only.nBdyRespErrors.inc

        if (1 < buddy.only.nBdyRespErrors and buddy.ctrl.stopped) or
           fetchBodiesReqThresholdCount < buddy.only.nBdyRespErrors:
          # Make sure that this peer does not immediately reconnect
          buddy.ctrl.zombie = true
        trace info & ": current block list discarded", peer, iv, ivReq,
          ctrl=buddy.ctrl.state, nRespErrors=buddy.only.nBdyRespErrors
        ctx.blocksUnprocCommit(iv.len, iv)
        # At this stage allow a task switch so that some other peer might try
        # to work on the currently returned interval.
        await sleepAsync asyncThreadSwitchTimeSlot
        return false

      # So there were some bodies downloaded already. Turn back unused data
      # and proceed with staging.
      trace info & ": list partially failed", peer, iv, ivReq,
        unused=BnRange.new(ivBottom,iv.maxPt)
      # There is some left over to store back
      ctx.blocksUnprocCommit(iv.len, ivBottom, iv.maxPt)
      break

    # Update remaining interval
    let ivRespLen = blk.blocks.len - nBlkBlocks
    if iv.maxPt < ivBottom + ivRespLen.uint64:
      # All collected
      ctx.blocksUnprocCommit(iv.len)
      break

    ivBottom += ivRespLen.uint64 # will mostly result into `ivReq.maxPt+1`

    if buddy.ctrl.stopped:
      # There is some left over to store back. And `ivBottom <= iv.maxPt`
      # because of the check against `ivRespLen` above.
      ctx.blocksUnprocCommit(iv.len, ivBottom, iv.maxPt)
      break

  # Store `blk` chain on the `staged` queue
  let qItem = ctx.blk.staged.insert(iv.minPt).valueOr:
    raiseAssert info & ": duplicate key on staged queue iv=" & $iv
  qItem.data = blk[]

  trace info & ": staged blocks", peer, bottomBlock=iv.minPt.bnStr,
    nBlocks=blk.blocks.len, nStaged=ctx.blk.staged.len, ctrl=buddy.ctrl.state

  return true


proc blocksStagedImport*(
    ctx: BeaconCtxRef;
    info: static[string];
      ): Future[bool]
      {.async.} =
  ## Import/execute blocks record from staged queue
  ##
  let qItem = ctx.blk.staged.ge(0).valueOr:
    return false

  # Fetch least record, accept only if it matches the global ledger state
  block:
    let imported = ctx.chain.latestNumber()
    if qItem.key != imported + 1:
      trace info & ": there is a gap L vs. staged",
        B=ctx.chain.baseNumber.bnStr, L=imported.bnStr, staged=qItem.key.bnStr,
        C=ctx.layout.coupler.bnStr
      doAssert imported < qItem.key
      return false

  # Remove from queue
  discard ctx.blk.staged.delete qItem.key

  let
    nBlocks = qItem.data.blocks.len
    iv = BnRange.new(qItem.key, qItem.key + nBlocks.uint64 - 1)

  trace info & ": import blocks ..", iv, nBlocks,
    B=ctx.chain.baseNumber.bnStr, L=ctx.chain.latestNumber.bnStr

  var maxImport = iv.maxPt
  block importLoop:
    for n in 0 ..< nBlocks:
      let nBn = qItem.data.blocks[n].header.number
      ctx.pool.chain.importBlock(qItem.data.blocks[n]).isOkOr:
        warn info & ": import block error", n, iv,
          B=ctx.chain.baseNumber.bnStr, L=ctx.chain.latestNumber.bnStr,
          nthBn=nBn.bnStr, nthHash=qItem.data.getNthHash(n), `error`=error
        # Restore what is left over below
        maxImport = ctx.chain.latestNumber()
        break importLoop

      # Allow pseudo/async thread switch.
      await sleepAsync asyncThreadSwitchTimeSlot
      if not ctx.daemon:
        # Shutdown?
        maxImport = ctx.chain.latestNumber()
        break importLoop

      # Update, so it can be followed nicely
      ctx.updateMetrics()

      # Occasionally mark the chain finalized
      if (n + 1) mod finaliserChainLengthMax == 0 or (n + 1) == nBlocks:
        let
          nthHash = qItem.data.getNthHash(n)
          finHash = if nBn < ctx.layout.final: nthHash
                    else: ctx.layout.finalHash

        doAssert nBn == ctx.chain.latestNumber()
        ctx.pool.chain.forkChoice(nthHash, finHash).isOkOr:
          warn info & ": fork choice error", n, iv,
            B=ctx.chain.baseNumber.bnStr, L=ctx.chain.latestNumber.bnStr,
            F=ctx.layout.final.bnStr, nthBn=nBn.bnStr, nthHash,
            finHash=(if finHash == nthHash: "nthHash" else: "F"), `error`=error
          # Restore what is left over below
          maxImport = ctx.chain.latestNumber()
          break importLoop

        # Allow pseudo/async thread switch.
        await sleepAsync asyncThreadSwitchTimeSlot
        if not ctx.daemon:
          maxImport = ctx.chain.latestNumber()
          break importLoop

  # Import probably incomplete, so a partial roll back may be needed
  if maxImport < iv.maxPt:
    ctx.blocksUnprocCommit(0, maxImport+1, qItem.data.blocks[^1].header.number)

  # Remove stashed headers for imported blocks
  for bn in iv.minPt .. maxImport:
    ctx.dbUnstashHeader bn

  # Update, so it can be followed nicely
  ctx.updateMetrics()

  trace info & ": import done", iv, nBlocks, B=ctx.chain.baseNumber.bnStr,
    L=ctx.chain.latestNumber.bnStr, F=ctx.layout.final.bnStr
  return true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
