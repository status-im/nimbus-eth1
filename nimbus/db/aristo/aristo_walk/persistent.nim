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

## Iterators for persistent backend of the Aristo DB
## =================================================
##
## This module automatically pulls in the persistent backend library at the
## linking stage (e.g. `rocksdb`) which can be avoided for pure memory DB
## applications by importing `./aristo_walk/memory_only` (rather than
## `./aristo_walk/persistent`.)
##
import
  ../aristo_init/[rocks_db, persistent],
  ".."/[aristo_desc, aristo_init],
  "."/[walk_private, memory_only]
export
  rocks_db,
  memory_only,
  persistent

# ------------------------------------------------------------------------------
# Public iterators (all in one)
# ------------------------------------------------------------------------------

iterator walkVtxBe*(
   T: type RdbBackendRef;
   db: AristoDbRef;
     ): tuple[n: int, vid: VertexID, vtx: VertexRef] =
  ## Iterate over filtered RocksDB backend vertices. This function depends on
  ## the particular backend type name which must match the backend descriptor.
  for (n,vid,vtx) in db.to(T).walkVtxBeImpl db:
    yield (n,vid,vtx)

iterator walkKeyBe*(
   T: type RdbBackendRef;
   db: AristoDbRef;
     ): tuple[n: int, vid: VertexID, key: HashKey] =
  ## Similar to `walkVtxBe()` but for keys.
  for (n,vid,key) in db.to(T).walkKeyBeImpl db:
    yield (n,vid,key)

iterator walkFilBe*(
   be: RdbBackendRef;
     ): tuple[n: int, qid: QueueID, filter: FilterRef] =
  ## Iterate over backend filters.
  for (n,qid,filter) in be.walkFilBeImpl:
    yield (n,qid,filter)

iterator walkFifoBe*(
   be: RdbBackendRef;
     ): (QueueID,FilterRef) =
  ## Walk filter slots in fifo order.
  for (qid,filter) in be.walkFifoBeImpl:
    yield (qid,filter)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
