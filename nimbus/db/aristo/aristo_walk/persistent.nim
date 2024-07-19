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

## Iterators for persistent backend of the Aristo DB
## =================================================
##
## This module automatically pulls in the persistent backend library at the
## linking stage (e.g. `rocksdb`) which can be avoided for pure memory DB
## applications by importing `./aristo_walk/memory_only` (rather than
## `./aristo_walk/persistent`.)
##
import
  ../aristo_init/[rocks_db, persistent], ../aristo_desc, "."/[walk_private, memory_only]

export rocks_db, memory_only, persistent

# ------------------------------------------------------------------------------
# Public iterators (all in one)
# ------------------------------------------------------------------------------

iterator walkVtxBe*[T: RdbBackendRef](
    _: type T, db: AristoDbRef
): tuple[rvid: RootedVertexID, vtx: VertexRef] =
  ## Iterate over filtered RocksDB backend vertices. This function depends on
  ## the particular backend type name which must match the backend descriptor.
  for (rvid, vtx) in walkVtxBeImpl[T](db):
    yield (rvid, vtx)

iterator walkKeyBe*[T: RdbBackendRef](
    _: type T, db: AristoDbRef
): tuple[rvid: RootedVertexID, key: HashKey] =
  ## Similar to `walkVtxBe()` but for keys.
  for (rvid, key) in walkKeyBeImpl[T](db):
    yield (rvid, key)

# -----------

iterator walkPairs*[T: RdbBackendRef](
    _: type T, db: AristoDbRef
): tuple[rvid: RootedVertexID, vtx: VertexRef] =
  ## Walk over all `(VertexID,VertexRef)` in the database. Note that entries
  ## are unsorted.
  for (rvid, vtx) in walkPairsImpl[T](db):
    yield (rvid, vtx)

iterator replicate*[T: RdbBackendRef](
    _: type T, db: AristoDbRef
): tuple[rvid: RootedVertexID, key: HashKey, vtx: VertexRef, node: NodeRef] =
  ## Variant of `walkPairsImpl()` for legacy applications.
  for (rvid, key, vtx, node) in replicateImpl[T](db):
    yield (rvid, key, vtx, node)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
