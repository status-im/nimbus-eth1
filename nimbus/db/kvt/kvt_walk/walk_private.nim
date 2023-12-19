# Nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  std/[algorithm, sets, tables],
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

  var
    seen: HashSet[Blob]
    i = 0
  for (key,data) in db.top.delta.sTab.pairs:
    if data.isValid:
      yield (i,key,data)
      i.inc
    seen.incl key

  for w in db.stack.reversed:
    for (key,data) in w.delta.sTab.pairs:
      if key notin seen:
        if data.isValid:
          yield (i,key,data)
          i.inc
        seen.incl key

  when T isnot VoidBackendRef:
    mixin walk

    for (n,key,data) in db.backend.T.walk:
      if key notin seen and data.isValid:
        yield (n+i,key,data)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
