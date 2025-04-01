# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Patricia Trie traversal
## ====================================
##
## This module provides tools to visit leaf vertices in a monotone order,
## increasing or decreasing. These tools are intended for
## * step along leaf vertices in sorted order
##

{.push raises: [].}

import
  eth/common/[base, hashes],
  results,
  "."/[aristo_desc, aristo_fetch, aristo_get, aristo_hike]

# ------------------------------------------------------------------------------
# Public functions, moving and right boundary proof
# ------------------------------------------------------------------------------

iterator rightPairs*(
    db: AristoTxRef;                    # Database layer
    root: VertexID;
      ): (Hash32,VertexRef) =
  ## Traverse the sub-trie implied by the argument `start` with increasing
  ## order.
  var
    next = root
    hike = Hike(root: root)

  while next.isValid():
    let vtx = db.getVtx((root, next))
    if not vtx.isValid:
      break
    hike.legs.add(Leg(nibble: -1, wp: VidVtxPair(vid: next, vtx: vtx)))
    reset(next)

    block nextLeg:
      while hike.legs.len > 0:
        var x = hike.legs[^1]

        case x.wp.vtx.vType
        of Branch:
          for i in uint8(x.nibble + 1)..<16u8:
            let b = x.wp.vtx.bVid(i)
            if b.isValid():
              hike.legs[^1].nibble = int8(i)

              next = b
              break nextLeg

          hike.legs.setLen(hike.legs.len - 1)
        of Leaf:
          yield (Hash32(hike.to(NibblesBuf).getBytes()), hike.legs[^1].wp.vtx)
          hike.legs.setLen(hike.legs.len - 1)

iterator rightPairsStorage*(
    db: AristoTxRef;                    # Database layer
    accPath: Hash32;                    # Account the storage data belong to
      ): (Hash32,UInt256) =
  ## Variant of `rightPairs()` for a storage tree
  block body:
    let stoID = db.fetchStorageID(accPath).valueOr:
      break body
    if stoID.isValid:
      for (path, vtx) in db.rightPairs(stoID):
        yield (path, vtx.lData.stoData)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
