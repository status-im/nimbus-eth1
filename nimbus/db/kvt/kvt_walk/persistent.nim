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

## Iterators for persistent backend of the Kvt DB
## ==============================================
##
## This module automatically pulls in the persistent backend library at the
## linking stage (e.g. `rocksdb`) which can be avoided for pure memory DB
## applications by importing `./kvt_walk/memory_only` (rather than
## `./kvt_walk/persistent`.)
##
import
  eth/common,
  ../kvt_init/[rocks_db, persistent],
  ./memory_only
export
  rocks_db,
  memory_only,
  persistent

# ------------------------------------------------------------------------------
# Public iterators (all in one)
# ------------------------------------------------------------------------------

iterator walkPairs*(
   be: RdbBackendRef;
     ): tuple[key: Blob, data: Blob] =
  ## Walk filter slots in fifo order.
  for (k,v) in be.walk:
    yield (k,v)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
