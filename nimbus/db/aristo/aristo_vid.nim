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

  # Down the rabbit hole of transaction layers
  let xDb = if db.cascaded: db.base else: db

  case xDb.vidGen.len:
  of 0:
    xDb.vidGen = @[2.VertexID]
    result = 1.VertexID
  of 1:
    result = xDb.vidGen[^1]
    xDb.vidGen = @[(result.uint64 + 1).VertexID]
  else:
    result = xDb.vidGen[^2]
    xDb.vidGen[^2] = xDb.vidGen[^1]
    xDb.vidGen.setLen(xDb.vidGen.len-1)


proc vidPeek*(db: AristoDbRef): VertexID =
  ## Like `new()` without consuming this *ID*. It will return the *ID* that
  ## would be returned by the `new()` function.

  # Down the rabbit hole of transaction layers
  let xDb = if db.cascaded: db.base else: db

  case xDb.vidGen.len:
  of 0:
    1.VertexID
  of 1:
    xDb.vidGen[^1]
  else:
    xDb.vidGen[^2]


proc vidDispose*(db: AristoDbRef; vtxID: VertexID) =
  ## Recycle the argument `vtxID` which is useful after deleting entries from
  ## the vertex table to prevent the `VertexID` type key values small.

  # Down the rabbit hole of transaction layers
  let xDb = if db.cascaded: db.base else: db

  if xDb.vidGen.len == 0:
    xDb.vidGen = @[vtxID]
  else:
    let topID = xDb.vidGen[^1]
    # No need to store smaller numbers: all numberts larger than `topID`
    # are free numbers
    if vtxID < topID:
      xDb.vidGen[^1] = vtxID
      xDb.vidGen.add topID

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
