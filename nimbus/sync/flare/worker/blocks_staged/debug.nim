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
  pkg/chronicles,
  pkg/eth/[common, p2p],
  pkg/stew/[interval_set, sorted_set],
  ../../../../common,
  ../../worker_desc,
  ../blocks_unproc

type
  BlocksForImportQueueWalk = SortedSetWalkRef[BlockNumber,BlocksForImport]
    ## Traversal descriptor (for `verifyStagedBlocksQueue()`)

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

proc verifyStagedBlocksQueue*(ctx: FlareCtxRef; info: static[string]) =
  ## Verify staged queue
  ##
  # Walk queue items
  let walk = BlocksForImportQueueWalk.init(ctx.blk.staged)
  defer: walk.destroy()

  var
    stTotal = 0u
    rc = walk.first()
    prv = BlockNumber(0)
  while rc.isOk:
    let
      key = rc.value.key
      nBlocks = rc.value.data.blocks.len.uint
      maxPt = key + nBlocks - 1
      unproc = ctx.blocksUnprocCovered(key, maxPt)
    if 0 < unproc:
      raiseAssert info & ": unprocessed staged chain " &
        key.bnStr & " overlap=" & $unproc
    if key <= prv:
      raiseAssert info & ": overlapping staged chain " &
        key.bnStr & " prvKey=" & prv.bnStr & " overlap=" & $(prv - key + 1)
    stTotal += nBlocks
    prv = maxPt
    rc = walk.next()

  let t = ctx.dbStateBlockNumber()

  if 0 < stTotal:
    let first = ctx.blk.staged.ge(0).value.key

    # Check `T < staged[] <= B`
    if first <= t:
      raiseAssert info & ": staged bottom mismatch " &
        " T=" & t.bnStr & " stBottom=" & first.bnStr
    if ctx.lhc.layout.base < prv:
      raiseAssert info & ": staged top mismatch " &
        " B=" & ctx.lhc.layout.base.bnStr & " stTop=" & prv.bnStr

  if 0 < ctx.blocksUnprocChunks:
    let
      uBottom = ctx.blocksUnprocBottom()
      uTop = ctx.blocksUnprocTop()
      topReq = ctx.blk.topRequest

    # Check `T < unprocessed{} <= B`
    if uBottom <= t:
      raiseAssert info & ": unproc bottom mismatch " &
        " T=" & t.bnStr & " uBottom=" & uBottom.bnStr
    if ctx.lhc.layout.base < uTop:
      raiseAssert info & ": unproc top mismatch " &
        " B=" & ctx.lhc.layout.base.bnStr & " uTop=" & uTop.bnStr
        
    # Check `unprocessed{} <= topRequest <= B`
    if topReq < uTop:
      raiseAssert info & ": unproc top req mismatch " &
        " uTop=" & uTop.bnStr & " topRequest=" & topReq.bnStr
    if ctx.lhc.layout.base < topReq:
      raiseAssert info & ": unproc top req mismatch " &
        " B=" & ctx.lhc.layout.base.bnStr & " topReq=" & topReq.bnStr

  # Check `staged[] + unprocessed{} == (T,B]`
  let
    uTotal = ctx.blocksUnprocTotal()
    uBorrowed = ctx.blocksUnprocBorrowed()
    all3 = stTotal + uTotal + uBorrowed
    unfilled = if t < ctx.layout.base: ctx.layout.base - t
               else: 0u

  trace info & ": verify staged", stTotal, uTotal, uBorrowed, all3, unfilled
  if unfilled < all3:
    raiseAssert info & ": staged/unproc too large" & " staged=" & $stTotal &
      " unproc=" & $uTotal & " borrowed=" & $uBorrowed & " exp-sum=" & $unfilled


proc verifyStagedBlocksItem*(blk: ref BlocksForImport; info: static[string]) =
  ## Verify record
  ##
  if blk.blocks.len == 0:
    trace info & ": verifying ok", nBlocks=0
    return

  trace info & ": verifying", nBlocks=blk.blocks.len

  if blk.blocks[0].header.txRoot != EMPTY_ROOT_HASH:
    doAssert 0 < blk.blocks[0].transactions.len
  else:
    doAssert blk.blocks[0].transactions.len == 0

  for n in 1 ..< blk.blocks.len:
    doAssert blk.blocks[n-1].header.number + 1 == blk.blocks[n].header.number

    if blk.blocks[n].header.txRoot != EMPTY_ROOT_HASH:
      doAssert 0 < blk.blocks[n].transactions.len
    else:
      doAssert blk.blocks[n].transactions.len == 0

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
