# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
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
  std/[algorithm, sequtils, sets, tables],
  ./aristo_desc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc vidFetch*(db: AristoDb): VertexID =
  ## Create a new `VertexID`. Reusable *ID*s are kept in a list where the top
  ## entry *ID0* has the property that any other *ID* larger *ID0* is also not
  ## not used on the database.
  let top = db.top
  case top.vGen.len:
  of 0:
    # Note that `VertexID(1)` is the root of the main trie
    top.vGen = @[VertexID(3)]
    result = VertexID(2)
  of 1:
    result = top.vGen[^1]
    top.vGen = @[VertexID(result.uint64 + 1)]
  else:
    result = top.vGen[^2]
    top.vGen[^2] = top.vGen[^1]
    top.vGen.setLen(top.vGen.len-1)


proc vidPeek*(db: AristoDb): VertexID =
  ## Like `new()` without consuming this *ID*. It will return the *ID* that
  ## would be returned by the `new()` function.
  case db.top.vGen.len:
  of 0:
    VertexID(2)
  of 1:
    db.top.vGen[^1]
  else:
    db.top.vGen[^2]


proc vidDispose*(db: AristoDb; vid: VertexID) =
  ## Recycle the argument `vtxID` which is useful after deleting entries from
  ## the vertex table to prevent the `VertexID` type key values small.
  if VertexID(1) < vid:
    if db.top.vGen.len == 0:
      db.top.vGen = @[vid]
    else:
      let topID = db.top.vGen[^1]
      # Only store smaller numbers: all numberts larger than `topID`
      # are free numbers
      if vid < topID:
        db.top.vGen[^1] = vid
        db.top.vGen.add topID

proc vidReorg*(db: AristoDb) =
  ## Remove redundant items from the recycle queue. All recycled entries are
  ## typically kept in the queue until the backend database is committed.
  if 1 < db.top.vGen.len:
    let lst = db.top.vGen.mapIt(uint64(it)).sorted.mapIt(VertexID(it))
    for n in (lst.len-1).countDown(1):
      if lst[n-1].uint64 + 1 != lst[n].uint64:
        # All elements larger than `lst[n-1` are in increasing order. For
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
          db.top.vGen.shallowCopy lst
          db.top.vGen.setLen(n+1)
        return
    # All entries are continuously increasing
    db.top.vGen = @[lst[0]]

proc vidAttach*(db: AristoDb; lbl: HashLabel; vid: VertexID) =
  ## Attach (i.r. register) a Merkle hash key to a vertex ID.
  db.top.dKey.excl vid
  db.top.pAmk[lbl] = vid
  db.top.kMap[vid] = lbl

proc vidAttach*(db: AristoDb; lbl: HashLabel): VertexID {.discardable.} =
  ## Variant of `vidAttach()` with auto-generated vertex ID
  result = db.vidFetch
  db.vidAttach(lbl, result)

proc vidRoot*(db: AristoDb; key: HashKey): VertexID {.discardable.} =
  ## Variant of `vidAttach()` for generating a sub-trie root
  result = db.vidFetch
  db.vidAttach(HashLabel(root: result, key: key), result)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
