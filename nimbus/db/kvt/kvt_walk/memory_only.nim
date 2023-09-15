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

## Iterators for non-persistent backend of the Kvt DB
## ==================================================
##
import
  eth/common,
  ../kvt_init/[memory_db, memory_only],
  ../kvt_init
export
  memory_db,
  memory_only

# ------------------------------------------------------------------------------
# Public iterators (all in one)
# ------------------------------------------------------------------------------

iterator walkPairs*(
   be: MemBackendRef|VoidBackendRef;
     ): tuple[key: Blob, data: Blob] =
  ## Iterate over backend filters.
  when be isnot VoidBackendRef:
    mixin walk

    for (k,v) in be.walk:
      yield (k,v)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
