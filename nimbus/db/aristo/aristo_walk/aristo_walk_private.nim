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

import
  std/[algorithm, sequtils, tables],
  ".."/[aristo_desc, aristo_init]

# ------------------------------------------------------------------------------
# Public generic iterators
# ------------------------------------------------------------------------------

iterator walkVtxBeImpl*[T](
    be: T;                             # Backend descriptor
    db: AristoDbRef;                   # Database with optional backend filter
      ): tuple[n: int, vid: VertexID, vtx: VertexRef] =
  ## Generic iterator
  var n = 0

  when be is VoidBackendRef:
    let filter = if db.roFilter.isNil: FilterRef() else: db.roFilter

  else:
    mixin walkVtx

    let filter = FilterRef()
    if not db.roFilter.isNil:
      filter.sTab = db.roFilter.sTab # copy table

    for (_,vid,vtx) in be.walkVtx:
      if filter.sTab.hasKey vid:
        let fVtx = filter.sTab.getOrVoid vid
        if fVtx.isValid:
          yield (n,vid,fVtx)
          n.inc
        filter.sTab.del vid
      else:
        yield (n,vid,vtx)
        n.inc

  for vid in filter.sTab.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID):
    let vtx = filter.sTab.getOrVoid vid
    if vtx.isValid:
      yield (n,vid,vtx)
      n.inc


iterator walkKeyBeImpl*[T](
    be: T;                             # Backend descriptor
    db: AristoDbRef;                   # Database with optional backend filter
      ): tuple[n: int, vid: VertexID, key: HashKey] =
  ## Generic iterator
  var n = 0

  when be is VoidBackendRef:
    let filter = if db.roFilter.isNil: FilterRef() else: db.roFilter

  else:
    mixin walkKey

    let filter = FilterRef()
    if not db.roFilter.isNil:
      filter.kMap = db.roFilter.kMap # copy table

    for (_,vid,key) in be.walkKey:
      if filter.kMap.hasKey vid:
        let fKey = filter.kMap.getOrVoid vid
        if fKey.isValid:
          yield (n,vid,fKey)
          n.inc
        filter.kMap.del vid
      else:
        yield (n,vid,key)
        n.inc

  for vid in filter.kMap.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID):
    let key = filter.kMap.getOrVoid vid
    if key.isValid:
      yield (n,vid,key)
      n.inc


iterator walkIdgBeImpl*[T](
    be: T;                             # Backend descriptor
    db: AristoDbRef;                   # Database with optional backend filter
      ): tuple[n: int, id: uint64, vGen: seq[VertexID]] =
  ## Generic pseudo iterator
  var nNext = 0
  if db.roFilter.isValid:
    yield(0, 0u64, db.roFilter.vGen)
    nNext = 1

  when be isnot VoidBackendRef:
    mixin walkIdg

    for (n,id,vGen) in be.walkIdg:
      if nNext <= n:
        yield(n,id,vGen)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
