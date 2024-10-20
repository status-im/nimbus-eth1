# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Iterators for non-persistent backend of the Aristo DB
## =====================================================
##
import
  ../aristo_init/[memory_db, memory_only],
  ".."/[aristo_desc, aristo_init],
  ./walk_private

export
  memory_db,
  memory_only

# ------------------------------------------------------------------------------
# Public iterators (all in one)
# ------------------------------------------------------------------------------

iterator walkVtxBe*[T: MemBackendRef|VoidBackendRef](
   _: type T;
   db: AristoDbRef;
     ): tuple[rvid: RootedVertexID, vtx: VertexRef] =
  ## Iterate over filtered memory backend or backend-less vertices. This
  ## function depends on the particular backend type name which must match
  ## the backend descriptor.
  for (rvid,vtx) in walkVtxBeImpl[T](db):
    yield (rvid,vtx)

iterator walkKeyBe*[T: MemBackendRef|VoidBackendRef](
   _: type T;
   db: AristoDbRef;
     ): tuple[rvid: RootedVertexID, key: HashKey] =
  ## Similar to `walkVtxBe()` but for keys.
  for (rvid,key) in walkKeyBeImpl[T](db):
    yield (rvid,key)

# -----------

iterator walkPairs*[T: MemBackendRef|VoidBackendRef](
   _: type T;
   db: AristoDbRef;
     ): tuple[rvid: RootedVertexID, vtx: VertexRef] =
  ## Walk over all `(VertexID,VertexRef)` in the database. Note that entries
  ## are unsorted.
  for (rvid,vtx) in walkPairsImpl[T](db):
    yield (rvid,vtx)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
