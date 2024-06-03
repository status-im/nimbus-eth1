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
  std/[typetraits],
  "."/[aristo_desc, aristo_layers]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc vidFetch*(db: AristoDbRef; pristine = false): VertexID =
  ## Recycle or create a new `VertexID`. Reusable vertex *ID*s are kept in a
  ## list where the top entry *ID* has the property that any other *ID* larger
  ## is also not used on the database.
  ##
  ## In most cases, this function will return a vid that's never been used,
  ## rolled back transactions and some disposals may however result in reuse.
  ##
  ## Earlier versions of this code maintained a free-list for recycling - this
  ## has been removed as maintenance of the free-list caused significant
  ## overhead due to implementation issues - a new implementation should be
  ## evaluated also from a database key perspective (since there may be
  ## advantages to using monotonically increasing keys)
  ##
  if db.vGen.uint64 < LEAST_FREE_VID:
    # Note that `VertexID(1)` is the root of the main trie
    db.top.final.vGen = VertexID(LEAST_FREE_VID + 1)
    result = VertexID(LEAST_FREE_VID)
  else:
    result = db.top.final.vGen
    db.top.final.vGen = VertexID(db.top.final.vGen.uint64 + 1)

proc vidDispose*(db: AristoDbRef; vid: VertexID) =
  ## Recycle the argument `vtxID` which is useful after deleting entries from
  ## the vertex table to prevent the `VertexID` type key values small.
  ##
  if LEAST_FREE_VID <= vid.distinctBase:
    if vid.uint64 == (db.vGen.uint64 + 1):
      # We can recycle the VertexID as long as there is no gap
      db.top.final.vGen = vid

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
