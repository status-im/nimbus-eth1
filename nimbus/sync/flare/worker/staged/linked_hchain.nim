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
  extraTraceMessages = false # or true
    ## Enabled additional logging noise

  verifyLinkedHChainOk = not defined(release) # or true
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

when verifyLinkedHChainOk:
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
# Private functions
# ------------------------------------------------------------------------------

proc newLHChain(
    rev: seq[BlockHeader];
    buddy: FlareBuddyRef;
    blockNumber: BlockNumber;
    topHash: Hash256;
    info: static[string];
      ): Opt[ref LinkedHChain] =
  ## Verify list of headers while assembling them to a `LinkedHChain`
  when extraTraceMessages:
    trace info, nHeaders=rev.len

  # Verify top block number
  assert 0 < rev.len # debugging only
  if rev[0].number != blockNumber:
    when extraTraceMessages:
      trace info & ": top block number mismatch",
        number=rev[0].number.bnStr, expected=blockNumber.bnStr
    return err()

  # Make space for return code array
  var chain = (ref LinkedHChain)(revHdrs: newSeq[Blob](rev.len))

  # Set up header with larges block number
  let blob0 = rlp.encode(rev[0])
  chain.revHdrs[0] = blob0
  chain.hash = blob0.keccakHash

  # Verify top block hash (if any)
  if topHash != EMPTY_ROOT_HASH and chain.hash != topHash:
    when extraTraceMessages:
      trace info & ": top block hash mismatch",
        hash=(chain.hash.data.toHex), expected=(topHash.data.toHex)
    return err()

  # Make sure that block headers are chained
  for n in 1 ..< rev.len:
    if rev[n].number + 1 != rev[n-1].number:
      when extraTraceMessages:
        trace info & ": #numbers mismatch", n,
          parentNumber=rev[n-1].number.bnStr, number=rev[n].number.bnStr
      return err()
    chain.revHdrs[n] = rlp.encode(rev[n])
    if rev[n-1].parentHash != chain.revHdrs[n].keccakHash:
      when extraTraceMessages:
        trace info & ": hash mismatch", n,
          parentHash=rev[n-1].parentHash, hash=chain.revHdrs[n].keccakHash
      return err()

  # Finalise
  chain.parentHash = rev[rev.len-1].parentHash

  when extraTraceMessages:
    trace info & " new chain record", nChain=chain.revHdrs.len
  ok(chain)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc extendLinkedHChain*(
  rev: seq[BlockHeader];
  buddy: FlareBuddyRef;
  blockNumber: BlockNumber;
  lhc: ref LinkedHChain; # update in place
  info: static[string];
    ): bool =

  when extraTraceMessages:
    let
      peer = buddy.peer
      isOpportunistic = lhc.parentHash == EMPTY_ROOT_HASH

  let newLhc = rev.newLHChain(buddy, blockNumber, lhc.parentHash, info).valueOr:
    when extraTraceMessages:
      trace info & ": fetched headers unusable", peer,
        blockNumber=blockNumber.bnStr, isOpportunistic
    return false

  # Prepend `newLhc` before `lhc`
  #
  # FIXME: This must be cleaned up and optimised at some point.
  #
  when extraTraceMessages:
    trace info & ": extending chain record", peer,
      blockNumber=blockNumber.bnStr, len=lhc.revHdrs.len,
      newLen=(newLhc.revHdrs.len + lhc.revHdrs.len), isOpportunistic

  if lhc.revHdrs.len == 0:
    lhc.hash = newLhc.hash
  lhc.revHdrs &= newLhc.revHdrs
  lhc.parentHash = newLhc.parentHash

  when verifyLinkedHChainOk:
    lhc.verifyHeaderChainItem info

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
