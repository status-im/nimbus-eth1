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
  pkg/stew/interval_set,
  ../../../../networking/p2p,
  ../../../wire_protocol/types,
  ../[helpers, update, worker_desc],
  ./[blocks_fetch, blocks_helpers, blocks_unproc]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc getNthHash(ctx: BeaconCtxRef; blocks: seq[EthBlock]; n: int): Hash32 =
  ctx.hdrCache.getHash(blocks[n].header.number).valueOr:
    return zeroHash32

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template blocksFetchCheckImpl(
    buddy: BeaconPeerRef;
    iv: BnRange;
    info: static[string];
      ): Opt[seq[EthBlock]] =
  ## Async/template
  ##
  ## From the ptp/ethXX network fetch the argument range `iv` of block bodies
  ## and assemble a list of blocks to be returned.
  ##
  ## The block bodies are heuristically verified, the headers are taken from
  ## the header chain cache.
  ##
  var bodyRc = Opt[seq[EthBlock]].err()
  block body:
    let
      ctx = buddy.ctx
      peer {.inject,used.} = $buddy.peer                   # logging only

    # Preset headers to be completed with bodies. Also collect block
    # hashes for fetching missing blocks.
    var
      request = BlockBodiesRequest(blockHashes: newSeqUninit[Hash32](iv.len))
      blocks = newSeq[EthBlock](iv.len)

    for n in 1u ..< iv.len:
      let header = ctx.hdrCache.get(iv.minPt + n).valueOr:
        # There is nothing one can do here
        chronicles.info "Block header missing (reorg triggered)", peer,
          iv=($iv), n, nth=(iv.minPt + n)
        ctx.subState.cancelRequest = true                  # So require reorg
        break body                                         # return err()
      request.blockHashes[n - 1] = header.parentHash
      blocks[n].header = header
    blocks[0].header = ctx.hdrCache.get(iv.minPt).valueOr:
      # There is nothing one can do here
      chronicles.info "Block header missing (reorg triggered)", peer,
        iv=($iv), n=0, nth=iv.minPt
      ctx.subState.cancelRequest = true                    # So require reorg
      break body                                           # return err()
    request.blockHashes[^1] = blocks[^1].header.computeBlockHash

    # Fetch bodies
    let bodies = buddy.fetchBodies(request).valueOr:
      break body                                           # return err()
    if buddy.ctrl.stopped:
      break body                                           # return err()

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
          blocks.setLen(n)                                 # curb off junk
          buddy.bdyFetchRegisterError()
          trace info & ": Cut off junk blocks", peer, iv=($iv), n=n,
            nTxs=bodies[n].transactions.len, nBodies,
            nErrors=buddy.nErrors.fetch.bdy
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
        blocks[n].uncles = bodies[n].uncles
        blocks[n].withdrawals = bodies[n].withdrawals

    if 0 < blocks.len.uint64:
      bodyRc = Opt[seq[EthBlock]].ok(blocks)               # return ok()

    buddy.nErrors.apply.blk.inc
    break body                                             # return err()

  bodyRc # return

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template blocksFetch*(
    buddy: BeaconPeerRef;
    num: uint;
    info: static[string];
      ): Opt[seq[EthBlock]] =
  ## Async/template
  ##
  ## From the p2p/ethXX network fetch as many blocks as given as argument `num`.
  ##
  let ctx = buddy.ctx

  var bodyRc = Opt[seq[EthBlock]].err()
  block body:
    # Make sure that this sync peer is not banned from block processing,
    # already.
    if nProcBlocksErrThreshold < buddy.nErrors.apply.blk:
      buddy.ctrl.zombie = true
      break body                                      # return err()

    let
      # Fetch next available interval
      iv = ctx.blocksUnprocFetch(num).valueOr:
        break body                                    # return err()

      # Fetch blocks and pre-verify result
      rc = buddy.blocksFetchCheckImpl(iv, info)

    # Job might have been cancelled or completed while downloading blocks.
    # If so, no more bookkeeping of blocks must take place. The *books*
    # might have been reset and prepared for the next stage.
    if ctx.blkSessionStopped():
      break body                                      # return err()

    # Commit blocks received
    if rc.isErr:
      ctx.blocksUnprocCommit(iv, iv)
    else:
      ctx.blocksUnprocCommit(iv, iv.minPt + rc.value.len.uint64, iv.maxPt)

    bodyRc = rc

  bodyRc # return


template blocksImport*(
    buddy: BeaconPeerRef;
    blocks: seq[EthBlock];
    peerID: Hash;
    info: static[string];
      ): uint64 =
  ## Async/template
  ##
  ## Import/execute a list of argument blocks. The function sets the global
  ## block number of the last executed block which might preceed the least block
  ## number from the argument list in case of an error.
  ##
  ## The template returns the number of blocks imported.
  ##
  var nBlocks = 0u64
  block body:
    let
      ctx = buddy.ctx
      peer {.inject,used.} = $buddy.peer           # logging only
      iv {.inject.} =
        BnRange.new(blocks[0].header.number, blocks[^1].header.number)
    doAssert iv.len == blocks.len.uint64

    var isError = false
    block loop:
      trace info & ": start importing blocks", peer, iv=($iv), nBlocks=iv.len,
        base=ctx.chain.baseNumber, head=ctx.chain.latestNumber

      for n in 0 ..< blocks.len:
        let nthBn = blocks[n].header.number

        # Hand the block to the `FC` and let it classify the outcome. The `FC`
        # owns the hash/branch/finalized knowledge needed to tell a duplicate or
        # an orphaned fork from a genuinely invalid block; the syncer must not
        # second-guess that from block numbers. `processQueue` already yields
        # per-item, so no extra throttle is needed here.
        let verdict =
          try:
            await ctx.chain.queueImportBlock(
              blocks[n], Opt.none(BlockAccessListRef))
          except CancelledError:
            break loop                               # await cancelled, stop

        if verdict.isOk:
          # `Valid` or `AlreadyObserved`: both are forward progress. A block
          # already present in the `FC` (imported earlier or by a concurrent
          # importer such as `el_sync`) advances `topNum` without a re-download.
          if verdict.value == AlreadyObserved:
            trace info & ": block already in FC", peer, blk=nthBn,
              B=ctx.chain.baseNumber, L=ctx.chain.latestNumber
          ctx.updateLastBlockImported nthBn          # block imported OK
          ctx.updateEtaBlocks()                      # metrics, eta estimate

          # Free block body immediately - ForkedChain only retains the header.
          # Transactions are already persisted as RLP bytes in the txFrame.
          blocks[n].reset()
          continue

        # Daemon stopped mid-import: abort the batch without committing.
        if not ctx.daemon:
          chronicles.debug "Blocks import stopped (syncer terminating)", n=n,
            iv=($iv), nBlocks=iv.len, nthBn,
            base=ctx.chain.baseNumber, head=ctx.chain.latestNumber
          break loop

        case verdict.error.kind
        of Orphaned, MissingParent:
          # The block could not be linked because the `FC` head moved (a
          # concurrent importer like `el_sync` advanced base/latest) or its
          # branch was cut off by finality. That is not the sync peer's fault:
          # stop the batch quietly and let the next job re-anchor on the live
          # head. An orphaned block's forward neighbours share its dead branch,
          # so the rest of this batch is dropped too. Do NOT advance `topNum`
          # and do NOT penalise the peer. A spin-guard still cancels the session
          # if the *same* block keeps failing.
          if ctx.subState.procFailNum != nthBn:
            ctx.subState.procFailNum = nthBn
            ctx.subState.procFailCount = 1
          else:
            ctx.subState.procFailCount.inc
            if nImportBlocksErrThreshold < ctx.subState.procFailCount:
              ctx.subState.cancelRequest = true
          trace info & ": batch stranded, FC head moved", peer, n=n, nthBn,
            kind=verdict.error.kind, nthHash=ctx.getNthHash(blocks, n).short,
            base=ctx.chain.baseNumber, head=ctx.chain.latestNumber,
            blkFailCount=ctx.subState.procFailCount, error=verdict.error.msg
          break loop

        of Invalid:
          # Genuine validation failure: the peer served an unusable block.
          isError = true

          # Mark peer that produced that unusable block as a zombie
          let srcPeer = buddy.getSyncPeer peerID
          if not srcPeer.isNil:
            srcPeer.only.nErrors.apply.blk = nProcBlocksErrThreshold + 1

          # Check whether it is enough to skip the current blocks list, only
          if ctx.subState.procFailNum != nthBn:
            ctx.subState.procFailNum = nthBn         # OK, this is a new block
            ctx.subState.procFailCount = 1
          else:
            ctx.subState.procFailCount.inc           # block num was seen, already

            # Cancel the whole download if needed
            if nImportBlocksErrThreshold < ctx.subState.procFailCount:
              ctx.subState.cancelRequest = true      # So require queue reset

          # Proper logging ..
          if ctx.subState.cancelRequest:
            warn "Blocks import error (cancel this session)", n=n, iv=($iv),
              nBlocks=iv.len, nthBn, nthHash=ctx.getNthHash(blocks, n).short,
              base=ctx.chain.baseNumber, head=ctx.chain.latestNumber,
              blkFailCount=ctx.subState.procFailCount, error=verdict.error.msg
          else:
            chronicles.info "Blocks import error (skip remaining)", n=n,
              iv=($iv), nBlocks=iv.len, nthBn,
              nthHash=ctx.getNthHash(blocks, n).short,
              base=ctx.chain.baseNumber, head=ctx.chain.latestNumber,
              blkFailCount=ctx.subState.procFailCount, error=verdict.error.msg
          break loop

        # End block: `loop`

    if not isError:
      let srcPeer = buddy.getSyncPeer peerID
      if not srcPeer.isNil:
        srcPeer.only.nErrors.apply.blk = 0

    nBlocks = ctx.subState.topNum - iv.minPt + 1   # number of blocks imported

    trace info & ": blocks imported", iv=(if iv.minPt <= ctx.subState.topNum:
      (iv.minPt, ctx.subState.topNum).toStr else: "n/a"), nBlocks,
      nFailed=(iv.maxPt - ctx.subState.topNum),
      base=ctx.chain.baseNumber, head=ctx.chain.latestNumber,
      target=ctx.subState.headNum, targetHash=ctx.subState.headHash.short
    # End block: `body`

  nBlocks                                          # return value

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
