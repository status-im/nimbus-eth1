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
  ../headers_unproc

type
  LinkedHChainQueueWalk = SortedSetWalkRef[BlockNumber,LinkedHChain]
    ## Traversal descriptor (for `verifyStagedQueue()`)

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

proc verifyStagedQueue*(ctx: FlareCtxRef; info: static[string]) =
  ## Verify stated queue, check that recorded ranges are no unprocessed,
  ## and return the total sise if headers covered.
  ##
  # Walk queue items
  let walk = LinkedHChainQueueWalk.init(ctx.lhc.staged)
  defer: walk.destroy()

  var
    stTotal = 0u
    rc = walk.first()
    prv = BlockNumber(0)
  while rc.isOk:
    let
      key = rc.value.key
      nHeaders = rc.value.data.revHdrs.len.uint
      minPt = key - nHeaders + 1
      unproc = ctx.headersUnprocCovered(minPt, key)
    if 0 < unproc:
      raiseAssert info & ": unprocessed staged chain " &
        key.bnStr & " overlap=" & $unproc
    if minPt <= prv:
      raiseAssert info & ": overlapping staged chain " &
        key.bnStr & " prvKey=" & prv.bnStr & " overlap=" & $(prv - minPt + 1)
    stTotal += nHeaders
    prv = key
    rc = walk.next()

  # Check `staged[] <= L`
  if ctx.layout.least <= prv:
    raiseAssert info & ": staged top mismatch " &
      " L=" & $ctx.layout.least.bnStr & " stagedTop=" & prv.bnStr

  # Check `unprocessed{} <= L`
  let uTop = ctx.headersUnprocTop()
  if ctx.layout.least <= uTop:
    raiseAssert info & ": unproc top mismatch " &
      " L=" & $ctx.layout.least.bnStr & " unprocTop=" & uTop.bnStr

  # Check `staged[] + unprocessed{} == (B,L)`
  let
    uTotal = ctx.headersUnprocTotal()
    uBorrowed = ctx.headersUnprocBorrowed()
    all3 = stTotal + uTotal + uBorrowed
    unfilled = if ctx.layout.least <= ctx.layout.base + 1: 0u
               else: ctx.layout.least - ctx.layout.base - 1

  trace info & ": verify staged", stTotal, uTotal, uBorrowed, all3, unfilled
  if all3 != unfilled:
    raiseAssert info & ": staged/unproc mismatch " & " staged=" & $stTotal &
      " unproc=" & $uTotal & " borrowed=" & $uBorrowed &
      " exp-sum=" & $unfilled


proc verifyHeaderChainItem*(lhc: ref LinkedHChain; info: static[string]) =
  ## Verify a header chain.
  if lhc.revHdrs.len == 0:
    trace info & ": verifying ok", nLhc=lhc.revHdrs.len
    return

  trace info & ": verifying", nLhc=lhc.revHdrs.len
  var
    topHdr, childHdr: BlockHeader
  try:
    doAssert lhc.revHdrs[0].keccakHash == lhc.hash
    topHdr = rlp.decode(lhc.revHdrs[0], BlockHeader)

    childHdr = topHdr
    for n in 1 ..< lhc.revHdrs.len:
      let header = rlp.decode(lhc.revHdrs[n], BlockHeader)
      doAssert childHdr.number == header.number + 1
      doAssert lhc.revHdrs[n].keccakHash == childHdr.parentHash
      childHdr = header

    doAssert childHdr.parentHash == lhc.parentHash
  except RlpError as e:
    raiseAssert "verifyHeaderChainItem oops(" & $e.name & ") msg=" & e.msg

  trace info & ": verify ok",
    iv=BnRange.new(childHdr.number,topHdr.number), nLhc=lhc.revHdrs.len

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
