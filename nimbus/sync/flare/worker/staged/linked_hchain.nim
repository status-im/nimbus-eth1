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
  pkg/eth/[common, p2p, rlp],
  pkg/stew/byteutils,
  ../../../../common,
  ../../worker_desc

const
  extraTraceMessages = false
    ## Enabled additional logging noise

  verifyDataStructureOk = false
    ## Debugging mode

when extraTraceMessages:
  import
    pkg/chronicles,
    stew/interval_set

  logScope:
    topics = "flare staged"

# ------------------------------------------------------------------------------
# Private debugging & logging helpers
# ------------------------------------------------------------------------------

proc `$`(w: Hash256): string =
  w.data.toHex

formatIt(Hash256):
  $it

when verifyDataStructureOk:
  proc verifyHeaderChainItem(lhc: ref LinkedHChain; info: static[string]) =
    when extraTraceMessages:
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

    when extraTraceMessages:
      trace info & ": verify ok",
        iv=BnRange.new(childHdr.number,topHdr.number), nLhc=lhc.revHdrs.len

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc extendLinkedHChain*(
  rev: seq[BlockHeader];
  buddy: FlareBuddyRef;
  topNumber: BlockNumber;
  lhc: ref LinkedHChain; # update in place
  info: static[string];
    ): bool =
  ## Returns sort of `lhc[] += rev[]` where `lhc[]` is updated in place.
  when extraTraceMessages:
    let peer = buddy.peer

  # Verify top block number
  assert 0 < rev.len # debugging only
  if rev[0].number != topNumber:
    when extraTraceMessages:
      trace info & ": top block number mismatch", peer, n=0,
        number=rev[0].number.bnStr, expected=topNumber.bnStr
    return false

  # Make space for return code array
  let offset = lhc.revHdrs.len
  lhc.revHdrs.setLen(offset + rev.len)

  # Set up header with largest block number
  let
    blob0 = rlp.encode(rev[0])
    hash0 = blob0.keccakHash
  lhc.revHdrs[offset] = blob0
  if offset == 0:
    lhc.hash = hash0

  # Verify top block hash (if any)
  if lhc.parentHash != EMPTY_ROOT_HASH and hash0 != lhc.parentHash:
    when extraTraceMessages:
      trace info & ": top hash mismatch", peer, hash0, expected=lhc.parentHash
    lhc.revHdrs.setLen(offset)
    return false

  # Encode block headers and make sure they are chained
  for n in 1 ..< rev.len:
    if rev[n].number + 1 != rev[n-1].number:
      when extraTraceMessages:
        trace info & ": #numbers mismatch", peer, n,
          parentNumber=rev[n-1].number.bnStr, number=rev[n].number.bnStr
      lhc.revHdrs.setLen(offset)
      return false

    lhc.revHdrs[offset + n] = rlp.encode(rev[n])
    let hashN = lhc.revHdrs[offset + n].keccakHash
    if rev[n-1].parentHash != hashN:
      when extraTraceMessages:
        trace info & ": hash mismatch", peer, n,
          parentHash=rev[n-1].parentHash, hashN
      lhc.revHdrs.setLen(offset)
      return false

  # Finalise
  lhc.parentHash = rev[rev.len-1].parentHash

  when extraTraceMessages:
    trace info & " extended chain record", peer, topNumber=topNumber.bnStr,
      offset, nLhc=lhc.revHdrs.len

  when verifyDataStructureOk:
    lhc.verifyHeaderChainItem info

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
