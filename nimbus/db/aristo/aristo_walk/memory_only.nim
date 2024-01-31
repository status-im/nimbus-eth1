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
     ): tuple[vid: VertexID, vtx: VertexRef] =
  ## Iterate over filtered memory backend or backend-less vertices. This
  ## function depends on the particular backend type name which must match
  ## the backend descriptor.
  for (vid,vtx) in walkVtxBeImpl[T](db):
    yield (vid,vtx)

iterator walkKeyBe*[T: MemBackendRef|VoidBackendRef](
   _: type T;
   db: AristoDbRef;
     ): tuple[vid: VertexID, key: HashKey] =
  ## Similar to `walkVtxBe()` but for keys.
  for (vid,key) in walkKeyBeImpl[T](db):
    yield (vid,key)

iterator walkFilBe*[T: MemBackendRef|VoidBackendRef](
   be: T;
     ): tuple[qid: QueueID, filter: FilterRef] =
  ## Iterate over backend filters.
  for (qid,filter) in walkFilBeImpl[T](be):
    yield (qid,filter)

iterator walkFifoBe*[T: MemBackendRef|VoidBackendRef](
   be: T;
     ):  tuple[qid: QueueID, fid: FilterRef] =
  ## Walk filter slots in fifo order.
  for (qid,filter) in walkFifoBeImpl[T](be):
    yield (qid,filter)

# -----------

iterator walkPairs*[T: MemBackendRef|VoidBackendRef](
   _: type T;
   db: AristoDbRef;
     ): tuple[vid: VertexID, vtx: VertexRef] =
  ## Walk over all `(VertexID,VertexRef)` in the database. Note that entries
  ## are unsorted.
  for (vid,vtx) in walkPairsImpl[T](db):
    yield (vid,vtx)

iterator replicate*[T: MemBackendRef|VoidBackendRef](
   _: type T;
   db: AristoDbRef;
    ): tuple[vid: VertexID, key: HashKey, vtx: VertexRef, node: NodeRef] =
  ## Variant of `walkPairsImpl()` for legacy applications.
  for (vid,key,vtx,node) in replicateImpl[T](db):
   yield (vid,key,vtx,node)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
