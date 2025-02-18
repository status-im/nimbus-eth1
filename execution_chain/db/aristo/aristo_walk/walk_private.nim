# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  ".."/[aristo_desc, aristo_layers]

# ------------------------------------------------------------------------------
# Public generic iterators
# ------------------------------------------------------------------------------

iterator walkVtxBeImpl*[T](
    db: AristoDbRef;                   # Database with optional backend filter
    kinds: set[VertexType];
      ): tuple[rvid: RootedVertexID, vtx: VertexRef] =
  ## Generic iterator
  mixin walkVtx

  let filter = AristoTxRef()
  if not db.txRef.isNil:
    filter.sTab = db.txRef.sTab # copy table

  for (rvid,vtx) in db.backend.T.walkVtx(kinds):
    if filter.sTab.hasKey rvid:
      let fVtx = filter.sTab.getOrVoid rvid
      if fVtx.isValid:
        yield (rvid,fVtx)
      filter.sTab.del rvid
    else:
      yield (rvid,vtx)

  for rvid in filter.sTab.keys:
    let vtx = filter.sTab.getOrVoid rvid
    if vtx.isValid:
      if vtx.vType notin kinds:
        continue
      yield (rvid,vtx)


iterator walkKeyBeImpl*[T](
    db: AristoDbRef;                   # Database with optional backend filter
      ): tuple[rvid: RootedVertexID, key: HashKey] =
  ## Generic iterator
  mixin walkKey

  let filter = AristoTxRef()
  if not db.txRef.isNil:
    filter.kMap = db.txRef.kMap # copy table

  for (rvid,key) in db.backend.T.walkKey:
    if filter.kMap.hasKey rvid:
      let fKey = filter.kMap.getOrVoid rvid
      if fKey.isValid:
        yield (rvid,fKey)
      filter.kMap.del rvid
    else:
      yield (rvid,key)

  for rvid in filter.kMap.keys.toSeq.sorted:
    let key = filter.kMap.getOrVoid rvid
    if key.isValid:
      yield (rvid,key)


iterator walkPairsImpl*[T](
   db: AristoDbRef;                   # Database with top layer & backend filter
     ): tuple[rvid: RootedVertexID, vtx: VertexRef] =
  ## Walk over all `(VertexID,VertexRef)` in the database. Note that entries
  ## are unsorted.
  var seen: HashSet[VertexID]
  for (rvid,vtx) in db.layersWalkVtx seen:
    if vtx.isValid:
      yield (rvid,vtx)

  for (rvid,vtx) in walkVtxBeImpl[T](db):
    if rvid.vid notin seen:
      yield (rvid,vtx)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
