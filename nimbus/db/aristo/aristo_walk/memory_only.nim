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

## Iterators for non-persistent backend of the Aristo DB
## =====================================================
##
import
  ../aristo_init/[aristo_memory, memory_only],
  ".."/[aristo_desc, aristo_init],
  ./aristo_walk_private
export
  aristo_memory,
  memory_only

# ------------------------------------------------------------------------------
# Public iterators (all in one)
# ------------------------------------------------------------------------------

iterator walkVtxBe*[T: MemBackendRef|NoneBackendRef](
   _: type T;
   db: AristoDbRef;
     ): tuple[n: int, vid: VertexID, vtx: VertexRef] =
  ## Iterate over filtered memory backend or backend-less vertices. This
  ## function depends on the particular backend type name which must match
  ## the backend descriptor.
  for (n,vid,vtx) in db.to(T).walkVtxBeImpl db:
    yield (n,vid,vtx)

iterator walkKeyBe*[T: MemBackendRef|NoneBackendRef](
   _: type T;
   db: AristoDbRef;
     ): tuple[n: int, vid: VertexID, key: HashKey] =
  ## Similar to `walkVtxBe()` but for keys.
  for (n,vid,key) in db.to(T).walkKeyBeImpl db:
    yield (n,vid,key)

iterator walkIdgBe*[T: MemBackendRef|NoneBackendRef](
   _: type T;
   db: AristoDbRef;
     ): tuple[n: int, vid: VertexID, vGen: seq[VertexID]] =
  ## Similar to `walkVtxBe()` but for vertex ID generator states.
  for (n,vid,vGen) in db.to(T).walkIdgBeImpl db:
    yield (n,vid,vGen)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
