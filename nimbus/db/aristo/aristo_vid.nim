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

proc vidFetch*(db: AristoDb): VertexID =
  ## Create a new `VertexID`. Reusable *ID*s are kept in a list where the top
  ## entry *ID0* has the property that any other *ID* larger *ID0* is also not
  ## not used on the database.
  let top = db.top
  case top.vGen.len:
  of 0:
    top.vGen = @[2.VertexID]
    result = 1.VertexID
  of 1:
    result = top.vGen[^1]
    top.vGen = @[(result.uint64 + 1).VertexID]
  else:
    result = top.vGen[^2]
    top.vGen[^2] = top.vGen[^1]
    top.vGen.setLen(top.vGen.len-1)


proc vidPeek*(db: AristoDb): VertexID =
  ## Like `new()` without consuming this *ID*. It will return the *ID* that
  ## would be returned by the `new()` function.
  let top = db.top
  case top.vGen.len:
  of 0:
    1.VertexID
  of 1:
    top.vGen[^1]
  else:
    top.vGen[^2]


proc vidDispose*(db: AristoDb; vid: VertexID) =
  ## Recycle the argument `vtxID` which is useful after deleting entries from
  ## the vertex table to prevent the `VertexID` type key values small.
  let top = db.top
  if top.vGen.len == 0:
    top.vGen = @[vid]
  else:
    let topID = top.vGen[^1]
    # Only store smaller numbers: all numberts larger than `topID`
    # are free numbers
    if vid < topID:
      top.vGen[^1] = vid
      top.vGen.add topID

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
