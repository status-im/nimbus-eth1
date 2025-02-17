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
  ../../../../common,
  ../../worker_desc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc extendLinkedHChain*(
  rev: seq[Header];
  buddy: BeaconBuddyRef;
  topNumber: BlockNumber;
  lhc: ref LinkedHChain; # update in place
    ): bool =
  ## Returns sort of `lhc[] += rev[]` where `lhc[]` is updated in place.

  # Verify top block number
  doAssert 0 < rev.len
  if rev[0].number != topNumber:
    return false

  # Make space for return code array
  let offset = lhc.revHdrs.len
  lhc.revHdrs.setLen(offset + rev.len)

  # Set up header with largest block number
  let
    blob0 = rlp.encode(rev[0])
    hash0 = blob0.keccak256
  lhc.revHdrs[offset] = blob0
  if offset == 0:
    lhc.hash = hash0

  # Verify top block hash (if any)
  if lhc.parentHash != emptyRoot and hash0 != lhc.parentHash:
    lhc.revHdrs.setLen(offset)
    return false

  # Encode block headers and make sure they are chained
  for n in 1 ..< rev.len:
    if rev[n].number + 1 != rev[n-1].number:
      lhc.revHdrs.setLen(offset)
      return false

    lhc.revHdrs[offset + n] = rlp.encode(rev[n])
    let hashN = lhc.revHdrs[offset + n].keccak256
    if rev[n-1].parentHash != hashN:
      lhc.revHdrs.setLen(offset)
      return false

  # Finalise
  lhc.parentHash = rev[rev.len-1].parentHash

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
