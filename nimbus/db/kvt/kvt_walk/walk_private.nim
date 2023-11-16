# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  std/tables,
  eth/common,
  ".."/[kvt_desc, kvt_init]

# ------------------------------------------------------------------------------
# Public generic iterators
# ------------------------------------------------------------------------------

iterator walkPairsImpl*[T](
   db: KvtDbRef;                   # Database with top layer & backend filter
     ): tuple[n: int, key: Blob, data: Blob] =
  ## Walk over all `(VertexID,VertexRef)` in the database. Note that entries
  ## are unsorted.

  var i = 0
  for (key,data) in db.top.tab.pairs:
    if data.isValid:
      yield (i,key,data)
      inc i

  when T isnot VoidBackendRef:
    mixin walk

    for (n,key,data) in db.backend.T.walk:
      if key notin db.top.tab and data.isValid:
        yield (n+i,key,data)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
