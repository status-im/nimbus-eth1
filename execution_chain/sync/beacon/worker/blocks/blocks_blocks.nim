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
  pkg/stew/interval_set,
  ../../../../networking/p2p,
  ../../../wire_protocol/types,
  ../../worker_desc,
  ./[blocks_fetch, blocks_helpers, blocks_unproc]

import
  ./blocks_debug

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc getNthHash(ctx: BeaconCtxRef; blocks: seq[EthBlock]; n: int): Hash32 =
  ctx.hdrCache.getHash(blocks[n].header.number).valueOr:
    return zeroHash32

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc blocksFetchCheckImpl(
    buddy: BeaconBuddyRef;
    iv: BnRange;
    info: static[string];
      ): Future[Opt[seq[EthBlock]]]
      {.async: (raises: []).} =
  ## From the ptp/ethXX network fetch the argument range `iv` of block bodies
  ## and assemble a list of blocks to be returned.
  ##
  ## The block bodies are heuristically verified, the headers are taken from
  ## the header chain cache.
  ##
  let
    ctx = buddy.ctx
    peer = buddy.peer

  # Preset/append headers to be completed with bodies. Also collect block hashes
  # for fetching missing blocks.
  var
    request = BlockBodiesRequest(blockHashes: newSeqUninit[Hash32](iv.len))
    blocks = newSeq[EthBlock](iv.len)

  for n in 1u ..< iv.len:
    let header = ctx.hdrCache.get(iv.minPt + n).valueOr:
      # There is nothing one can do here
      info "Block header missing (reorg triggered)", peer, iv, n,
        nth=(iv.minPt + n).bnStr
      ctx.subState.cancelRequest = true                    # So require reorg
      return Opt.none(seq[EthBlock])
    request.blockHashes[n - 1] = header.parentHash
    blocks[n].header = header
  blocks[0].header = ctx.hdrCache.get(iv.minPt).valueOr:
    # There is nothing one can do here
    info "Block header missing (reorg triggered)", peer, iv, n=0,
      nth=iv.minPt.bnStr
    ctx.subState.cancelRequest = true                      # So require reorg
    return Opt.none(seq[EthBlock])
  request.blockHashes[^1] = blocks[^1].header.computeBlockHash

  # Fetch bodies
  let bodies = (await buddy.fetchBodies(request, info)).valueOr:
    return Opt.none(seq[EthBlock])
  if buddy.ctrl.stopped:
    return Opt.none(seq[EthBlock])

  # Append bodies, note that the bodies are not fully verified here but rather
  # when they are imported and executed.
  let nBodies = bodies.len.uint64
  if nBodies < iv.len:
    blocks.setLen(nBodies)
  block loop:
    for n in 0 ..< nBodies:
      block checkTxLenOk:
        if blocks[n].header.transactionsRoot != emptyRoot:
          if 0 < bodies[n].transactions.len:
            break checkTxLenOk
        else:
          if bodies[n].transactions.len == 0:
            break checkTxLenOk
        # Oops, cut off the rest
        blocks.setLen(n)                                   # curb off junk
        buddy.bdyFetchRegisterError()
        trace info & ": Cut off junk blocks", peer, iv, n,
          nTxs=bodies[n].transactions.len, nBodies, bdyErrors=buddy.bdyErrors
        break loop

      # In order to avoid extensive checking here and also within the `FC`
      # module, thourough checking is left to the `FC` module. Staging a few
      # bogus blocks is not too expensive.
      #
      # If there is a mere block body error, all that will happen is that
      # this block and the rest of the `blocks[]` list is discarded. This
      # is also what will happen here if an error is detected (see above for
      # erroneously empty `transactions[]`.)
      #
      blocks[n].transactions = bodies[n].transactions
      blocks[n].uncles       = bodies[n].uncles
      blocks[n].withdrawals  = bodies[n].withdrawals

  if 0 < blocks.len.uint64:
    return Opt.some(blocks)

  buddy.incBlkProcErrors()
  return Opt.none(seq[EthBlock])

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc blocksFetch*(
    buddy: BeaconBuddyRef;
    num: uint;
    info: static[string];
      ): Future[Opt[seq[EthBlock]]]
      {.async: (raises: []).} =
  ## From the p2p/ethXX network fetch as many blocks as given as argument `num`.
  let ctx = buddy.ctx

  # Make sure that this sync peer is not banned from block processing, already.
  if nProcBlocksErrThreshold < buddy.nBlkProcErrors():
    buddy.ctrl.zombie = true
    return Opt.none(seq[EthBlock])                  # stop, exit this function

  let
    # Fetch next available interval
    iv = ctx.blocksUnprocFetch(num).valueOr:
      return Opt.none(seq[EthBlock])

    # Fetch blocks and pre-verify result
    rc = await buddy.blocksFetchCheckImpl(iv, info)

  # Job might have been cancelled or completed while downloading blocks.
  # If so, no more bookkeeping of blocks must take place. The *books*
  # might have been reset and prepared for the next stage.
  if ctx.blkSessionStopped():
    return Opt.none(seq[EthBlock])                  # stop, exit this function

  # Commit blocks received
  if rc.isErr:
    ctx.blocksUnprocCommit(iv, iv)
  else:
    ctx.blocksUnprocCommit(iv, iv.minPt + rc.value.len.uint64, iv.maxPt)

  return rc


proc blocksImport*(
    ctx: BeaconCtxRef;
    maybePeer: Opt[BeaconBuddyRef];
    blocks: seq[EthBlock];
    peerID: Hash;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Import/execute a list of argument blocks. The function sets the global
  ## block number of the last executed block which might preceed the least block
  ## number from the argument list in case of an error.
  ##
  let iv = BnRange.new(blocks[0].header.number, blocks[^1].header.number)
  doAssert iv.len == blocks.len.uint64
  doAssert ctx.blk.verify()

  trace info & ": Start importing blocks", peer=maybePeer.toStr, iv,
    nBlocks=iv.len, base=ctx.chain.baseNumber.bnStr,
    head=ctx.chain.latestNumber.bnStr, blk=ctx.blk.bnStr

  var isError = false
  block loop:
    for n in 0 ..< blocks.len:
      let nBn = blocks[n].header.number
      discard (await ctx.handler.importBlock(
                 ctx, maybePeer, blocks[n], peerID)).valueOr:
        if error.excp != ECancelledError:
          isError = true

          # Mark peer that produced that unusable headers list as a zombie
          ctx.setBlkProcFail peerID

          # Check whether it is enough to skip the current blocks list, only
          if ctx.subState.procFailNum != nBn:
            ctx.subState.procFailNum = nBn         # OK, this is a new block
            ctx.subState.procFailCount = 1

          else:
            ctx.subState.procFailCount.inc         # block num was seen, already

            # Cancel the whole download if needed
            if nImportBlocksErrThreshold < ctx.subState.procFailCount:
              ctx.subState.cancelRequest = true    # So require queue reset

          # Proper logging ..
          if ctx.subState.cancelRequest:
            warn "Import error (cancel this session)", n, iv,
              nBlocks=iv.len, nthBn=nBn.bnStr,
              nthHash=ctx.getNthHash(blocks, n).short,
              base=ctx.chain.baseNumber.bnStr,
              head=ctx.chain.latestNumber.bnStr,
              blkFailCount=ctx.subState.procFailCount, `error`=error
          else:
            info "Import error (skip remaining)", n, iv,
              nBlocks=iv.len, nthBn=nBn.bnStr,
              nthHash=ctx.getNthHash(blocks, n).short,
              base=ctx.chain.baseNumber.bnStr,
              head=ctx.chain.latestNumber.bnStr,
              blkFailCount=ctx.subState.procFailCount, `error`=error

        break loop

      # isOk => next instruction
      ctx.subState.top = nBn                       # Block imported OK

  if not isError:
    ctx.resetBlkProcErrors peerID

  info "Imported blocks", iv=(if iv.minPt <= ctx.subState.top:
    (iv.minPt, ctx.subState.top).bnStr else: "n/a"),
    nBlocks=(ctx.subState.top - iv.minPt + 1),
    nFailed=(iv.maxPt - ctx.subState.top),
    base=ctx.chain.baseNumber.bnStr, head=ctx.chain.latestNumber.bnStr,
    target=ctx.subState.head.bnStr, targetHash=ctx.subState.headHash.short,
    blk=ctx.blk.bnStr

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
