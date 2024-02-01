# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Handle vertex IDs on the layered Aristo DB delta architecture
## =============================================================

{.push raises: [].}

import
  std/[algorithm, sequtils, typetraits],
  "."/[aristo_desc, aristo_layers]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc vidFetch*(db: AristoDbRef; pristine = false): VertexID =
  ## Create a new `VertexID`. Reusable vertex *ID*s are kept in a list where
  ## the top entry *ID* has the property that any other *ID* larger is also not
  ## not used on the database.
  ##
  ## The function prefers to return recycled vertex *ID*s if there are any.
  ## When the argument `pristine` is set `true`, the function guarantees to
  ## return a non-recycled, brand new vertex *ID* which is the preferred mode
  ## when creating leaf vertices.
  if db.vGen.len == 0:
    # Note that `VertexID(1)` is the root of the main trie
    db.top.final.vGen = @[VertexID(LEAST_FREE_VID+1)]
    result = VertexID(LEAST_FREE_VID)
  elif db.vGen.len == 1 or pristine:
    result = db.vGen[^1]
    db.top.final.vGen[^1] = result + 1
  else:
    result = db.vGen[^2]
    db.top.final.vGen[^2] = db.top.final.vGen[^1]
    db.top.final.vGen.setLen(db.vGen.len-1)
  doAssert LEAST_FREE_VID <= result.distinctBase


proc vidPeek*(db: AristoDbRef): VertexID =
  ## Like `new()` without consuming this *ID*. It will return the *ID* that
  ## would be returned by the `new()` function.
  case db.vGen.len:
  of 0:
    VertexID(LEAST_FREE_VID)
  of 1:
    db.vGen[^1]
  else:
    db.vGen[^2]


proc vidDispose*(db: AristoDbRef; vid: VertexID) =
  ## Recycle the argument `vtxID` which is useful after deleting entries from
  ## the vertex table to prevent the `VertexID` type key values small.
  if LEAST_FREE_VID <= vid.distinctBase:
    if db.vGen.len == 0:
      db.top.final.vGen = @[vid]
    else:
      let topID = db.vGen[^1]
      # Only store smaller numbers: all numberts larger than `topID`
      # are free numbers
      if vid < topID:
        db.top.final.vGen[^1] = vid
        db.top.final.vGen.add topID

proc vidReorg*(vGen: seq[VertexID]): seq[VertexID] =
  ## Return a compacted version of the argument vertex ID generator state
  ## `vGen`. The function removes redundant items from the recycle queue.
  if 1 < vGen.len:
    let lst = vGen.mapIt(uint64(it)).sorted.mapIt(VertexID(it))
    for n in (lst.len-1).countDown(1):
      if lst[n-1].uint64 + 1 != lst[n].uint64:
        # All elements larger than `lst[n-1]` are in increasing order. For
        # the last continuously increasing sequence, only the smallest item
        # is needed and the rest can be removed
        #
        # Example:
        #         ..3, 5, 6, 7     =>   ..3, 5
        #              ^
        #              |
        #              n
        #
        if n < lst.len-1:
          return lst[0..n]
        return vGen
    # All entries are continuously increasing
    return @[lst[0]]

  vGen

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
