# Nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  ../kvt_desc,
  "."/[memory_only, walk_private]

export
  rocks_db,
  memory_only,
  persistent

# ------------------------------------------------------------------------------
# Public iterators (all in one)
# ------------------------------------------------------------------------------

iterator walkPairs*(
   T: type RdbBackendRef;
   db: KvtDbRef;
     ): tuple[key: seq[byte], data: seq[byte]] =
  ## Iterate over backend filters.
  for (key,data) in walkPairsImpl[T](db):
    yield (key,data)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
