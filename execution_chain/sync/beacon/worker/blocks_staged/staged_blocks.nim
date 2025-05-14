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
  ../../../wire_protocol/types,
  ../../worker_desc,
  ../[blocks_unproc, helpers, update],
  ./bodies

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

formatIt(Hash32):
  it.short

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
  ## ...
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
      ctx.poolMode = true                                  # So require reorg
      return Opt.none(seq[EthBlock])
    request.blockHashes[n - 1] = header.parentHash
    blocks[n].header = header
  blocks[0].header = ctx.hdrCache.get(iv.minPt).valueOr:
    # There is nothing one can do here
    info "Block header missing (reorg triggered)", peer, iv, n=0,
      nth=iv.minPt.bnStr
    ctx.poolMode = true                                    # So require reorg
    return Opt.none(seq[EthBlock])
  request.blockHashes[^1] = blocks[^1].header.computeBlockHash

  # Fetch bodies
  let bodies = (await buddy.bodiesFetch(request, info)).valueOr:
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
        buddy.fetchRegisterError()
        trace info & ": cut off junk blocks", peer, iv, n,
          nTxs=bodies[n].transactions.len, nBodies, bdyErrors=buddy.bdyErrors
        break loop

      blocks[n].transactions = bodies[n].transactions
      blocks[n].uncles       = bodies[n].uncles
      blocks[n].withdrawals  = bodies[n].withdrawals

  if 0 < blocks.len.uint64:
    return Opt.some(blocks)

  buddy.only.nBdyProcErrors.inc
  return Opt.none(seq[EthBlock])

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func blocksModeStopped*(ctx: BeaconCtxRef): bool =
  ## Helper, checks whether there is a general stop conditions based on
  ## state settings (not on sync peer ctrl as `buddy.ctrl.running`.)
  ctx.poolMode or
  ctx.pool.lastState != processingBlocks


proc blocksFetch*(
    buddy: BeaconBuddyRef;
    num: uint;
    info: static[string];
      ): Future[Opt[seq[EthBlock]]]
      {.async: (raises: []).} =
  ## ...
  let
    ctx = buddy.ctx

    # Fetch nect available interval
    iv = ctx.blocksUnprocFetch(num).valueOr:
      return Opt.none(seq[EthBlock])

    # Fetch blocks and verify result
    rc = await buddy.blocksFetchCheckImpl(iv, info)

  # Commit blocks received
  if rc.isErr:
    ctx.blocksUnprocCommit(iv, iv)
  else:
    ctx.blocksUnprocCommit(iv, iv.minPt + rc.value.len.uint64, iv.maxPt)

  return rc


proc blocksImport*(
    ctx: BeaconCtxRef;
    blocks: seq[EthBlock];
    info: static[string];
      ) {.async: (raises: []).} =
  ## Import/execute a list of argument blocks. The function sets the global
  ## block number of the last executed block which might preceed the least block
  ## number from the argument list in case of an error.
  ##
  let iv = BnRange.new(blocks[0].header.number, blocks[^1].header.number)
  doAssert iv.len == blocks.len.uint64

  info "Importing blocks", iv, nBlocks=blocks.len,
    base=ctx.chain.baseNumber.bnStr, head=ctx.chain.latestNumber.bnStr,
    target=ctx.head.bnStr

  block loop:
    for n in 0 ..< blocks.len:
      let nBn = blocks[n].header.number

      if nBn <= ctx.chain.baseNumber:
        trace info & ": ignoring block less eq. base", n, iv, nBlocks=iv.len,
          nthBn=nBn.bnStr, nthHash=ctx.getNthHash(blocks, n),
          B=ctx.chain.baseNumber.bnStr, L=ctx.chain.latestNumber.bnStr

        ctx.blk.topImported = nBn                  # well, not really imported
        continue

      try:
        (await ctx.chain.importBlock(blocks[n])).isOkOr:
          # The way out here is simply to re-compile the block queue. At any
          # point, the `FC` module data area might have been moved to a new
          # canonical branch.
          #
          ctx.poolMode = true
          warn info & ": import block error (reorg triggered)", n, iv,
            nBlocks=iv.len, nthBn=nBn.bnStr, nthHash=ctx.getNthHash(blocks, n),
            B=ctx.chain.baseNumber.bnStr, L=ctx.chain.latestNumber.bnStr,
            `error`=error
          break loop
        # isOk => next instruction
      except CancelledError:
        break loop                                 # shutdown?

      ctx.blk.topImported = nBn                    # Block imported OK

      # Allow pseudo/async thread switch.
      (await ctx.updateAsyncTasks()).isOkOr:
        break loop
      
  info "Import done", iv=(if iv.minPt <= ctx.blk.topImported:
    (iv.minPt, ctx.blk.topImported).bnStr else: "n/a"),
    nBlocks=(ctx.blk.topImported - iv.minPt + 1),
    nFailed=(iv.maxPt - ctx.blk.topImported),
    base=ctx.chain.baseNumber.bnStr, head=ctx.chain.latestNumber.bnStr,
    target=ctx.head.bnStr

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
