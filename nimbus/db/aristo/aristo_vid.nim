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
  ./aristo_desc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc vidFetch*(db: AristoDbRef): VertexID =
  ## Create a new `VertexID`. Reusable *ID*s are kept in a list where the top
  ## entry *ID0* has the property that any other *ID* larger *ID0* is also not
  ## not used on the database.
  case db.vGen.len:
  of 0:
    db.vGen = @[2.VertexID]
    result = 1.VertexID
  of 1:
    result = db.vGen[^1]
    db.vGen = @[(result.uint64 + 1).VertexID]
  else:
    result = db.vGen[^2]
    db.vGen[^2] = db.vGen[^1]
    db.vGen.setLen(db.vGen.len-1)


proc vidPeek*(db: AristoDbRef): VertexID =
  ## Like `new()` without consuming this *ID*. It will return the *ID* that
  ## would be returned by the `new()` function.
  case db.vGen.len:
  of 0:
    1.VertexID
  of 1:
    db.vGen[^1]
  else:
    db.vGen[^2]


proc vidDispose*(db: AristoDbRef; vid: VertexID) =
  ## Recycle the argument `vtxID` which is useful after deleting entries from
  ## the vertex table to prevent the `VertexID` type key values small.
  if db.vGen.len == 0:
    db.vGen = @[vid]
  else:
    let topID = db.vGen[^1]
    # Only store smaller numbers: all numberts larger than `topID`
    # are free numbers
    if vid < topID:
      db.vGen[^1] = vid
      db.vGen.add topID

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
