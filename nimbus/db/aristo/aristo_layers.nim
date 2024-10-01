# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[enumerate, sequtils, sets, tables],
  eth/common,
  results,
  ./aristo_desc

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func dup(sTab: Table[RootedVertexID,VertexRef]): Table[RootedVertexID,VertexRef] =
  ## Explicit dup for `VertexRef` values
  for (k,v) in sTab.pairs:
    result[k] = v.dup

# ------------------------------------------------------------------------------
# Public getters: lazy value lookup for read only versions
# ------------------------------------------------------------------------------

func vTop*(db: AristoDbRef): VertexID =
  db.top.vTop

# ------------------------------------------------------------------------------
# Public getters/helpers
# ------------------------------------------------------------------------------

func nLayersVtx*(db: AristoDbRef): int =
  ## Number of vertex ID/vertex entries on the cache layers. This is an upper
  ## bound for the number of effective vertex ID mappings held on the cache
  ## layers as there might be duplicate entries for the same vertex ID on
  ## different layers.
  ##
  db.stack.mapIt(it.sTab.len).foldl(a + b, db.top.sTab.len)

func nLayersKey*(db: AristoDbRef): int =
  ## Number of vertex ID/key entries on the cache layers. This is an upper
  ## bound for the number of effective vertex ID mappingss held on the cache
  ## layers as there might be duplicate entries for the same vertex ID on
  ## different layers.
  ##
  db.stack.mapIt(it.kMap.len).foldl(a + b, db.top.kMap.len)

# ------------------------------------------------------------------------------
# Public functions: getter variants
# ------------------------------------------------------------------------------

func layersGetVtx*(db: AristoDbRef; rvid: RootedVertexID): Opt[(VertexRef, int)] =
  ## Find a vertex on the cache layers. An `ok()` result might contain a
  ## `nil` vertex if it is stored on the cache  that way.
  ##
  db.top.sTab.withValue(rvid, item):
    return Opt.some((item[], 0))

  for i, w in enumerate(db.rstack):
    w.sTab.withValue(rvid, item):
      return Opt.some((item[], i + 1))

  Opt.none((VertexRef, int))

func layersGetVtxOrVoid*(db: AristoDbRef; rvid: RootedVertexID): VertexRef =
  ## Simplified version of `layersGetVtx()`
  db.layersGetVtx(rvid).valueOr((VertexRef(nil), 0))[0]


func layersGetKey*(db: AristoDbRef; rvid: RootedVertexID): Opt[(HashKey, int)] =
  ## Find a hash key on the cache layers. An `ok()` result might contain a void
  ## hash key if it is stored on the cache that way.
  ##
  db.top.kMap.withValue(rvid, item):
    return Opt.some((item[], 0))

  for i, w in enumerate(db.rstack):
    w.kMap.withValue(rvid, item):
      return ok((item[], i + 1))

  Opt.none((HashKey, int))

func layersGetKeyOrVoid*(db: AristoDbRef; rvid: RootedVertexID): HashKey =
  ## Simplified version of `layersGetKey()`
  (db.layersGetKey(rvid).valueOr (VOID_HASH_KEY, 0))[0]

func layersGetAccLeaf*(db: AristoDbRef; accPath: Hash32): Opt[VertexRef] =
  db.top.accLeaves.withValue(accPath, item):
    return Opt.some(item[])

  for w in db.rstack:
    w.accLeaves.withValue(accPath, item):
      return Opt.some(item[])

  Opt.none(VertexRef)

func layersGetStoLeaf*(db: AristoDbRef; mixPath: Hash32): Opt[VertexRef] =
  db.top.stoLeaves.withValue(mixPath, item):
    return Opt.some(item[])

  for w in db.rstack:
    w.stoLeaves.withValue(mixPath, item):
      return Opt.some(item[])

  Opt.none(VertexRef)

# ------------------------------------------------------------------------------
# Public functions: setter variants
# ------------------------------------------------------------------------------

func layersPutVtx*(
    db: AristoDbRef;
    rvid: RootedVertexID;
    vtx: VertexRef;
      ) =
  ## Store a (potentally empty) vertex on the top layer
  db.top.sTab[rvid] = vtx

func layersResVtx*(
    db: AristoDbRef;
    rvid: RootedVertexID;
      ) =
  ## Shortcut for `db.layersPutVtx(vid, VertexRef(nil))`. It is sort of the
  ## equivalent of a delete function.
  db.layersPutVtx(rvid, VertexRef(nil))


func layersPutKey*(
    db: AristoDbRef;
    rvid: RootedVertexID;
    key: HashKey;
      ) =
  ## Store a (potentally void) hash key on the top layer
  db.top.kMap[rvid] = key


func layersResKey*(db: AristoDbRef; rvid: RootedVertexID) =
  ## Shortcut for `db.layersPutKey(vid, VOID_HASH_KEY)`. It is sort of the
  ## equivalent of a delete function.
  db.layersPutKey(rvid, VOID_HASH_KEY)

func layersResKeys*(db: AristoDbRef; hike: Hike) =
  ## Reset all cached keys along the given hike
  for i in 1..hike.legs.len:
    db.layersResKey((hike.root, hike.legs[^i].wp.vid))

proc layersUpdateVtx*(
    db: AristoDbRef;                   # Database, top layer
    rvid: RootedVertexID;
    vtx: VertexRef;                    # Vertex to add
      ) =
  ## Update a vertex at `rvid` and reset its associated key entry
  db.layersPutVtx(rvid, vtx)
  db.layersResKey(rvid)

func layersPutAccLeaf*(db: AristoDbRef; accPath: Hash32; leafVtx: VertexRef) =
  db.top.accLeaves[accPath] = leafVtx

func layersPutStoLeaf*(db: AristoDbRef; mixPath: Hash32; leafVtx: VertexRef) =
  db.top.stoLeaves[mixPath] = leafVtx

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func isEmpty*(ly: LayerRef): bool =
  ## Returns `true` if the layer does not contain any changes, i.e. all the
  ## tables are empty. The field `txUid` is ignored, here.
  ly.sTab.len == 0 and
  ly.kMap.len == 0 and
  ly.accLeaves.len == 0 and
  ly.stoLeaves.len == 0


func layersMergeOnto*(src: LayerRef; trg: var LayerObj) =
  ## Merges the argument `src` into the argument `trg` and returns `trg`. For
  ## the result layer, the `txUid` value set to `0`.
  ##
  trg.txUid = 0

  for (vid,vtx) in src.sTab.pairs:
    trg.sTab[vid] = vtx
  for (vid,key) in src.kMap.pairs:
    trg.kMap[vid] = key
  trg.vTop = src.vTop
  for (accPath,leafVtx) in src.accLeaves.pairs:
    trg.accLeaves[accPath] = leafVtx
  for (mixPath,leafVtx) in src.stoLeaves.pairs:
    trg.stoLeaves[mixPath] = leafVtx

func layersCc*(db: AristoDbRef; level = high(int)): LayerRef =
  ## Provide a collapsed copy of layers up to a particular transaction level.
  ## If the `level` argument is too large, the maximum transaction level is
  ## returned. For the result layer, the `txUid` value set to `0`.
  ##
  let layers = if db.stack.len <= level: db.stack & @[db.top]
               else:                     db.stack[0 .. level]

  # Set up initial layer (bottom layer)
  result = LayerRef(
    sTab: layers[0].sTab.dup,          # explicit dup for ref values
    kMap: layers[0].kMap,
    vTop: layers[^1].vTop,
    accLeaves: layers[0].accLeaves,
    stoLeaves: layers[0].stoLeaves)

  # Consecutively merge other layers on top
  for n in 1 ..< layers.len:
    for (vid,vtx) in layers[n].sTab.pairs:
      result.sTab[vid] = vtx
    for (vid,key) in layers[n].kMap.pairs:
      result.kMap[vid] = key
    for (accPath,vtx) in layers[n].accLeaves.pairs:
      result.accLeaves[accPath] = vtx
    for (mixPath,vtx) in layers[n].stoLeaves.pairs:
      result.stoLeaves[mixPath] = vtx

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator layersWalkVtx*(
    db: AristoDbRef;
    seen: var HashSet[VertexID];
      ): tuple[rvid: RootedVertexID, vtx: VertexRef] =
  ## Walk over all `(VertexID,VertexRef)` pairs on the cache layers. Note that
  ## entries are unsorted.
  ##
  ## The argument `seen` collects a set of all visited vertex IDs including
  ## the one with a zero vertex which are othewise skipped by the iterator.
  ## The `seen` argument must not be modified while the iterator is active.
  ##
  for (rvid,vtx) in db.top.sTab.pairs:
    yield (rvid,vtx)
    seen.incl rvid.vid

  for w in db.rstack:
    for (rvid,vtx) in w.sTab.pairs:
      if rvid.vid notin seen:
        yield (rvid,vtx)
        seen.incl rvid.vid

iterator layersWalkVtx*(
    db: AristoDbRef;
      ): tuple[rvid: RootedVertexID, vtx: VertexRef] =
  ## Variant of `layersWalkVtx()`.
  var seen: HashSet[VertexID]
  for (rvid,vtx) in db.layersWalkVtx seen:
    yield (rvid,vtx)


iterator layersWalkKey*(
    db: AristoDbRef;
      ): tuple[rvid: RootedVertexID, key: HashKey] =
  ## Walk over all `(VertexID,HashKey)` pairs on the cache layers. Note that
  ## entries are unsorted.
  var seen: HashSet[VertexID]
  for (rvid,key) in db.top.kMap.pairs:
    yield (rvid,key)
    seen.incl rvid.vid

  for w in db.rstack:
    for (rvid,key) in w.kMap.pairs:
      if rvid.vid notin seen:
        yield (rvid,key)
        seen.incl rvid.vid

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
