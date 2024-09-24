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
  pkg/eth/[common, p2p],
  pkg/stew/[interval_set, sorted_set],
  ../../../common,
  ../../../core/chain,
  ../worker_desc,
  ./blocks_staged/bodies,
  "."/[blocks_unproc, db]

logScope:
  topics = "flare blocks"

const
  verifyDataStructureOk = true
    ## Debugging mode

when verifyDataStructureOk:
  import ./blocks_staged/debug

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc fetchAndCheck(
    buddy: FlareBuddyRef;
    ivReq: BnRange;
    blk: ref BlocksForImport; # update in place
    info: static[string];
      ): Future[bool] {.async.} =

  let
    ctx = buddy.ctx
    offset = blk.blocks.len.uint

  # Make sure that the block range matches the top
  doAssert offset == 0 or blk.blocks[offset - 1].header.number+1 == ivReq.minPt

  # Preset/append headers to be completed with bodies. Also collect block hashes
  # for fetching missing blocks.
  blk.blocks.setLen(offset + ivReq.len)
  var blockHash = newSeq[Hash256](ivReq.len)
  for n in 1u ..< ivReq.len:
    let header = ctx.dbPeekHeader(ivReq.minPt + n).expect "stashed header"
    blockHash[n - 1] = header.parentHash
    blk.blocks[offset + n].header = header
  blk.blocks[offset].header =
    ctx.dbPeekHeader(ivReq.minPt).expect "stashed header"
  blockHash[ivReq.len - 1] =
    rlp.encode(blk.blocks[offset + ivReq.len - 1].header).keccakHash

  # Fetch bodies
  let bodies = block:
    let rc = await buddy.bodiesFetch(blockHash, info)
    if rc.isErr:
      blk.blocks.setLen(offset)
      return false
    rc.value

  # Append bodies, note that the bodies are not fully verified here but rather
  # when they are imported and executed.
  let nBodies = bodies.len.uint
  if nBodies < ivReq.len:
    blk.blocks.setLen(offset + nBodies)
  block loop:
    for n in 0 ..< nBodies:
      block checkTxLenOk:
        if blk.blocks[offset + n].header.txRoot != EMPTY_ROOT_HASH:
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
      blk.blocks[offset + n].requests     = bodies[n].requests

  return offset < blk.blocks.len.uint

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc blocksStagedCanImportOk*(ctx: FlareCtxRef): bool =
  ## Check whether the queue is at its maximum size so import can start with
  ## a full queue.
  if blocksStagedQueueLengthMax <= ctx.blk.staged.len:
    return true

  # What is on the queue might be all we have got.
  if 0 < ctx.blk.staged.len and
     ctx.blocksUnprocChunks() == 0 and
     ctx.blocksUnprocBorrowed() == 0:
    return true

  false

proc blocksStagedFetchOk*(ctx: FlareCtxRef): bool =
  ## Check whether body records can be fetched and stored on the `staged` queue.
  ##
  let uBottom = ctx.blocksUnprocBottom()
  if uBottom < high(BlockNumber):
    # Not to start fetching while the queue is busy (i.e. larger than Lwm)
    # so that import might still be running strong.
    if ctx.blk.staged.len < blocksStagedQueueLengthMax:
      return true

    # Make sure that there is no gap at the bottom which needs to be
    # addressed regardless of the length of the queue.
    if uBottom < ctx.blk.staged.ge(0).value.key:
      return true

  false


proc blocksStagedCollect*(
    buddy: FlareBuddyRef;
    info: static[string];
      ): Future[bool] {.async.} =
  ## Collect bodies and stage them.
  ##
  if buddy.ctx.blocksUnprocChunks() == 0:
    # Nothing to do
    return false

  let
    ctx = buddy.ctx
    peer = buddy.peer

    # Fetch the full range of headers to be completed to blocks
    iv = ctx.blocksUnprocFetch(nFetchBodiesBatch).expect "valid interval"

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
      if nBlkBlocks == 0:
        if 0 < buddy.only.nBdyRespErrors and buddy.ctrl.stopped:
          # Make sure that this peer does not immediately reconnect
          buddy.ctrl.zombie = true
        trace info & ": completely failed", peer, iv, ivReq,
          ctrl=buddy.ctrl.state, nRespErrors=buddy.only.nBdyRespErrors
        ctx.blocksUnprocCommit(iv.len, iv)
        # At this stage allow a task switch so that some other peer might try
        # to work on the currently returned interval.
        await sleepAsync asyncThreadSwitchTimeSlot
        return false

      # So there were some bodies downloaded already. Turn back unused data
      # and proceed with staging.
      trace info & ": partially failed", peer, iv, ivReq,
        unused=BnRange.new(ivBottom,iv.maxPt)
      # There is some left over to store back
      ctx.blocksUnprocCommit(iv.len, ivBottom, iv.maxPt)
      break

    # Update remaining interval
    let ivRespLen = blk.blocks.len - nBlkBlocks
    if iv.maxPt < ivBottom + ivRespLen.uint:
      # All collected
      ctx.blocksUnprocCommit(iv.len)
      break

    ivBottom += ivRespLen.uint # will mostly result into `ivReq.maxPt+1`

    if buddy.ctrl.stopped:
      # There is some left over to store back. And `ivBottom <= iv.maxPt`
      # because of the check against `ivRespLen` above.
      ctx.blocksUnprocCommit(iv.len, ivBottom, iv.maxPt)
      break

  when verifyDataStructureOk:
    blk.verifyStagedBlocksItem info

  # Store `blk` chain on the `staged` queue
  let qItem = ctx.blk.staged.insert(iv.minPt).valueOr:
    raiseAssert info & ": duplicate key on staged queue iv=" & $iv
  qItem.data = blk[]

  trace info & ": staged blocks", peer, bottomBlock=iv.minPt.bnStr,
    nBlocks=blk.blocks.len, nStaged=ctx.blk.staged.len, ctrl=buddy.ctrl.state

  when verifyDataStructureOk:
    ctx.verifyStagedBlocksQueue info

  return true


proc blocksStagedImport*(ctx: FlareCtxRef; info: static[string]): bool =
  ## Import/execute blocks record from staged queue
  ##
  let qItem = ctx.blk.staged.ge(0).valueOr:
    return false

  # Fetch least record, accept only if it matches the global ledger state
  let t = ctx.dbStateBlockNumber()
  if qItem.key != t + 1:
    trace info & ": there is a gap", T=t.bnStr, stagedBottom=qItem.key.bnStr
    return false

  # Remove from queue
  discard ctx.blk.staged.delete qItem.key

  # Execute blocks
  let stats = ctx.pool.chain.persistBlocks(qItem.data.blocks).valueOr:
    # FIXME: should that be rather an `raiseAssert` here?
    warn info & ": block exec error", T=t.bnStr,
      iv=BnRange.new(qItem.key,qItem.key+qItem.data.blocks.len.uint-1), error
    doAssert t == ctx.dbStateBlockNumber()
    return false

  trace info & ": imported staged blocks", T=ctx.dbStateBlockNumber.bnStr,
    first=qItem.key.bnStr, stats

  # Remove stashed headers
  for bn in qItem.key ..< qItem.key + qItem.data.blocks.len.uint:
    ctx.dbUnstashHeader bn

  when verifyDataStructureOk:
    ctx.verifyStagedBlocksQueue info

  true


proc blocksStagedBottomKey*(ctx: FlareCtxRef): BlockNumber =
  ## Retrieve to staged block number
  let qItem = ctx.blk.staged.ge(0).valueOr:
    return high(BlockNumber)
  qItem.key

proc blocksStagedQueueLen*(ctx: FlareCtxRef): int =
  ## Number of staged records
  ctx.blk.staged.len

proc blocksStagedQueueIsEmpty*(ctx: FlareCtxRef): bool =
  ## `true` iff no data are on the queue.
  ctx.blk.staged.len == 0

# ----------------

proc blocksStagedInit*(ctx: FlareCtxRef) =
  ## Constructor
  ctx.blk.staged = StagedBlocksQueue.init()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
