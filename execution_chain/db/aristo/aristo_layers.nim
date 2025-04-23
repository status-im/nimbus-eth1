# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[sets, tables],
  eth/common/hashes,
  results,
  ./aristo_desc,
  ../../utils/mergeutils

# ------------------------------------------------------------------------------
# Public functions: getter variants
# ------------------------------------------------------------------------------

func layersGetVtx*(db: AristoTxRef; rvid: RootedVertexID): Opt[(VertexRef, int)] =
  ## Find a vertex on the cache layers. An `ok()` result might contain a
  ## `nil` vertex if it is stored on the cache  that way.
  ##
  for w in db.rstack(stopAtSnapshot = true):
    if w.snapshot.level.isSome():
      w.snapshot.vtx.withValue(rvid, item):
        return Opt.some((item[][0], item[][2]))
      break

    w.sTab.withValue(rvid, item):
      return Opt.some((item[], w.level))

  Opt.none((VertexRef, int))

func layersGetKey*(db: AristoTxRef; rvid: RootedVertexID): Opt[(HashKey, int)] =
  ## Find a hash key on the cache layers. An `ok()` result might contain a void
  ## hash key if it is stored on the cache that way.
  ##

  for w in db.rstack(stopAtSnapshot = true):
    if w.snapshot.level.isSome():
      w.snapshot.vtx.withValue(rvid, item):
        return Opt.some((item[][1], item[][2]))
      break

    w.kMap.withValue(rvid, item):
      return ok((item[], w.level))
    if rvid in w.sTab:
      return Opt.some((VOID_HASH_KEY, w.level))

  Opt.none((HashKey, int))

func layersGetKeyOrVoid*(db: AristoTxRef; rvid: RootedVertexID): HashKey =
  ## Simplified version of `layersGetKey()`
  (db.layersGetKey(rvid).valueOr (VOID_HASH_KEY, 0))[0]

func layersGetAccLeaf*(db: AristoTxRef; accPath: Hash32): Opt[AccLeafRef] =
  for w in db.rstack(stopAtSnapshot = true):
    if w.snapshot.level.isSome():
      w.snapshot.acc.withValue(accPath, item):
        return Opt.some(item[][0])
      break

    w.accLeaves.withValue(accPath, item):
      return Opt.some(item[])

  Opt.none(AccLeafRef)

func layersGetStoLeaf*(db: AristoTxRef; mixPath: Hash32): Opt[StoLeafRef] =
  for w in db.rstack(stopAtSnapshot = true):
    if w.snapshot.level.isSome():
      w.snapshot.sto.withValue(mixPath, item):
        return Opt.some(item[][0])
      break

    w.stoLeaves.withValue(mixPath, item):
      return Opt.some(item[])

  Opt.none(StoLeafRef)

# ------------------------------------------------------------------------------
# Public functions: setter variants
# ------------------------------------------------------------------------------

func layersPutVtx*(
    db: AristoTxRef;
    rvid: RootedVertexID;
    vtx: VertexRef;
      ) =
  ## Store a (potentally empty) vertex on the top layer
  db.sTab[rvid] = vtx
  db.kMap.del(rvid)

  if db.snapshot.level.isSome():
    db.snapshot.vtx[rvid] = (vtx, VOID_HASH_KEY, db.level)

func layersResVtx*(
    db: AristoTxRef;
    rvid: RootedVertexID;
      ) =
  ## Shortcut for `db.layersPutVtx(vid, VertexRef(nil))`. It is sort of the
  ## equivalent of a delete function.
  db.layersPutVtx(rvid, VertexRef(nil))

func layersPutKey*(
    db: AristoTxRef;
    rvid: RootedVertexID;
    vtx: VertexRef,
    key: HashKey;
      ) =
  ## Store a (potentally void) hash key on the top layer
  db.sTab[rvid] = vtx
  db.kMap[rvid] = key

  if db.snapshot.level.isSome():
    db.snapshot.vtx[rvid] = (vtx, key, db.level)

func layersResKey*(db: AristoTxRef; rvid: RootedVertexID, vtx: VertexRef) =
  ## Shortcut for `db.layersPutKey(vid, VOID_HASH_KEY)`. It is sort of the
  ## equivalent of a delete function.
  db.layersPutVtx(rvid, vtx)

func layersResKeys*(db: AristoTxRef; hike: Hike, skip: int) =
  ## Reset all cached keys along the given hike
  for i in (skip + 1)..hike.legs.len:
    db.layersResKey((hike.root, hike.legs[^i].wp.vid), hike.legs[^i].wp.vtx)

func layersPutAccLeaf*(db: AristoTxRef; accPath: Hash32; leafVtx: AccLeafRef) =
  db.accLeaves[accPath] = leafVtx

  if db.snapshot.level.isSome():
    db.snapshot.acc[accPath] = (leafVtx, db.level)

func layersPutStoLeaf*(db: AristoTxRef; mixPath: Hash32; leafVtx: StoLeafRef) =
  db.stoLeaves[mixPath] = leafVtx

  if db.snapshot.level.isSome():
    db.snapshot.sto[mixPath] = (leafVtx, db.level)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func isEmpty*(ly: AristoTxRef): bool =
  ## Returns `true` if the layer does not contain any changes, i.e. all the
  ## tables are empty.
  ly.snapshot.vtx.len == 0 and
  ly.snapshot.acc.len == 0 and
  ly.snapshot.sto.len == 0 and
  ly.sTab.len == 0 and
  ly.kMap.len == 0 and
  ly.accLeaves.len == 0 and
  ly.stoLeaves.len == 0

proc copyFrom*(snapshot: var Snapshot, tx: AristoTxRef) =
  for rvid, vtx in tx.sTab:
    tx.kMap.withValue(rvid, key):
      snapshot.vtx[rvid] = (vtx, key[], tx.level)
    do:
      snapshot.vtx[rvid] = (vtx, VOID_HASH_KEY, tx.level)

  for k, v in tx.accLeaves:
    snapshot.acc[k] = (v, tx.level)
  for k, v in tx.stoLeaves:
    snapshot.sto[k] = (v, tx.level)

proc mergeAndDiscard*(trg, src: var HashKey) =
  trg = src

proc mergeAndReset*(trg, src: AristoTxRef) =
  ## Merges the argument `src` into the argument `trg` and clears `src`.
  trg.vTop = src.vTop
  trg.blockNumber = src.blockNumber
  trg.level = src.level
  trg.parent = move(src.parent)

  doAssert not src.snapshot.level.isSome(),
    "If the source is a snapshot, it should have been used as a starting point for merge"

  if trg.snapshot.level.isSome():
    # If there already was a snapshot, we might as well add to it
    trg.snapshot.copyFrom(src)
    src.sTab.reset()
    src.kMap.reset()
  else:
    if trg.kMap.len > 0:
      # Invalidate cached keys in the lower layer
      for vid in src.sTab.keys:
        trg.kMap.del vid

    mergeAndReset(trg.sTab, src.sTab)
    mergeAndReset(trg.kMap, src.kMap)

  mergeAndReset(trg.accLeaves, src.accLeaves)
  mergeAndReset(trg.stoLeaves, src.stoLeaves)

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator layersWalkVtx*(
    db: AristoTxRef;
    seen: var HashSet[VertexID];
      ): tuple[rvid: RootedVertexID, vtx: VertexRef] =
  ## Walk over all `(VertexID,VertexRef)` pairs on the cache layers. Note that
  ## entries are unsorted.
  ##
  ## The argument `seen` collects a set of all visited vertex IDs including
  ## the one with a zero vertex which are othewise skipped by the iterator.
  ## The `seen` argument must not be modified while the iterator is active.
  ##
  for w in db.rstack:
    for (rvid,vtx) in w.sTab.pairs:
      if not seen.containsOrIncl(rvid.vid):
        yield (rvid,vtx)

iterator layersWalkVtx*(
    db: AristoTxRef;
      ): tuple[rvid: RootedVertexID, vtx: VertexRef] =
  ## Variant of `layersWalkVtx()`.
  var seen: HashSet[VertexID]
  for (rvid,vtx) in db.layersWalkVtx seen:
    yield (rvid,vtx)


iterator layersWalkKey*(
    db: AristoTxRef;
      ): tuple[rvid: RootedVertexID, key: HashKey] =
  ## Walk over all `(VertexID,HashKey)` pairs on the cache layers. Note that
  ## entries are unsorted.
  var seen: HashSet[VertexID]
  for w in db.rstack:
    for (rvid,key) in w.kMap.pairs:
      if not seen.containsOrIncl(rvid.vid):
        yield (rvid,key)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
