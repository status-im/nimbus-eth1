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
  pkg/stew/interval_set,
  ../../worker_desc,
  ../[helpers, update]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

formatIt(Hash32):
  it.short

proc getNthHash(ctx: BeaconCtxRef; blocks: seq[EthBlock]; n: int): Hash32 =
  ctx.hdrCache.getHash(blocks[n].header.number).valueOr:
    return zeroHash32

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

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
