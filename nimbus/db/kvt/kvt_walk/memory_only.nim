# Nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Iterators for non-persistent backend of the Kvt DB
## ==================================================
##
import
  eth/common,
  ../kvt_init/[memory_db, memory_only],
  ".."/[kvt_desc, kvt_init],
  ./walk_private

export
  memory_db,
  memory_only

# ------------------------------------------------------------------------------
# Public iterators (all in one)
# ------------------------------------------------------------------------------

iterator walkPairs*[T: MemBackendRef|VoidBackendRef](
   _: type T;
   db: KvtDbRef;
     ): tuple[key: Blob, data: Blob] =
  ## Iterate over backend filters.
  for (key,data) in walkPairsImpl[T](db):
    yield (key,data)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
