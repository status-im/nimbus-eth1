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

import
  std/[algorithm, sequtils, sets, tables],
  results,
  ".."/[aristo_desc, aristo_get, aristo_init, aristo_layers, aristo_utils]

# ------------------------------------------------------------------------------
# Public generic iterators
# ------------------------------------------------------------------------------

iterator walkVtxBeImpl*[T](
    db: AristoDbRef;                   # Database with optional backend filter
      ): tuple[vid: VertexID, vtx: VertexRef] =
  ## Generic iterator
  when T is VoidBackendRef:
    let filter = if db.balancer.isNil: FilterRef() else: db.balancer

  else:
    mixin walkVtx

    let filter = FilterRef()
    if not db.balancer.isNil:
      filter.sTab = db.balancer.sTab # copy table

    for (vid,vtx) in db.backend.T.walkVtx:
      if filter.sTab.hasKey vid:
        let fVtx = filter.sTab.getOrVoid vid
        if fVtx.isValid:
          yield (vid,fVtx)
        filter.sTab.del vid
      else:
        yield (vid,vtx)

  for vid in filter.sTab.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID):
    let vtx = filter.sTab.getOrVoid vid
    if vtx.isValid:
      yield (vid,vtx)


iterator walkKeyBeImpl*[T](
    db: AristoDbRef;                   # Database with optional backend filter
      ): tuple[vid: VertexID, key: HashKey] =
  ## Generic iterator
  when T is VoidBackendRef:
    let filter = if db.balancer.isNil: FilterRef() else: db.balancer

  else:
    mixin walkKey

    let filter = FilterRef()
    if not db.balancer.isNil:
      filter.kMap = db.balancer.kMap # copy table

    for (vid,key) in db.backend.T.walkKey:
      if filter.kMap.hasKey vid:
        let fKey = filter.kMap.getOrVoid vid
        if fKey.isValid:
          yield (vid,fKey)
        filter.kMap.del vid
      else:
        yield (vid,key)

  for vid in filter.kMap.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID):
    let key = filter.kMap.getOrVoid vid
    if key.isValid:
      yield (vid,key)


iterator walkPairsImpl*[T](
   db: AristoDbRef;                   # Database with top layer & backend filter
     ): tuple[vid: VertexID, vtx: VertexRef] =
  ## Walk over all `(VertexID,VertexRef)` in the database. Note that entries
  ## are unsorted.
  var seen: HashSet[VertexID]
  for (vid,vtx) in db.layersWalkVtx seen:
    if vtx.isValid:
      yield (vid,vtx)

  for (vid,vtx) in walkVtxBeImpl[T](db):
    if vid notin seen:
      yield (vid,vtx)

iterator replicateImpl*[T](
   db: AristoDbRef;                   # Database with top layer & backend filter
     ): tuple[vid: VertexID, key: HashKey, vtx: VertexRef, node: NodeRef] =
  ## Variant of `walkPairsImpl()` for legacy applications.
  for (vid,vtx) in walkPairsImpl[T](db):
    let node = block:
      let rc = vtx.toNode(db)
      if rc.isOk:
        rc.value
      else:
        NodeRef(nil)
    yield (vid, db.getKey vid, vtx, node)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
