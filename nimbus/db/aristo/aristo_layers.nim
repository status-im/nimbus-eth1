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
  std/[sequtils, sets, tables],
  eth/common,
  results,
  ./aristo_desc

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func dup(sTab: Table[VertexID,VertexRef]): Table[VertexID,VertexRef] =
  ## Explicit dup for `VertexRef` values
  for (k,v) in sTab.pairs:
    result[k] = v.dup

# ------------------------------------------------------------------------------
# Public getters: lazy value lookup for read only versions
# ------------------------------------------------------------------------------

func vTop*(db: AristoDbRef): VertexID =
  db.top.delta.vTop

# ------------------------------------------------------------------------------
# Public getters/helpers
# ------------------------------------------------------------------------------

func nLayersVtx*(db: AristoDbRef): int =
  ## Number of vertex ID/vertex entries on the cache layers. This is an upper
  ## bound for the number of effective vertex ID mappings held on the cache
  ## layers as there might be duplicate entries for the same vertex ID on
  ## different layers.
  ##
  db.stack.mapIt(it.delta.sTab.len).foldl(a + b, db.top.delta.sTab.len)

func nLayersKey*(db: AristoDbRef): int =
  ## Number of vertex ID/key entries on the cache layers. This is an upper
  ## bound for the number of effective vertex ID mappingss held on the cache
  ## layers as there might be duplicate entries for the same vertex ID on
  ## different layers.
  ##
  db.stack.mapIt(it.delta.kMap.len).foldl(a + b, db.top.delta.kMap.len)

# ------------------------------------------------------------------------------
# Public functions: getter variants
# ------------------------------------------------------------------------------

func layersGetVtx*(db: AristoDbRef; vid: VertexID): Opt[VertexRef] =
  ## Find a vertex on the cache layers. An `ok()` result might contain a
  ## `nil` vertex if it is stored on the cache  that way.
  ##
  db.top.delta.sTab.withValue(vid, item):
    return Opt.some(item[])

  for w in db.rstack:
    w.delta.sTab.withValue(vid, item):
      return Opt.some(item[])

  Opt.none(VertexRef)

func layersGetVtxOrVoid*(db: AristoDbRef; vid: VertexID): VertexRef =
  ## Simplified version of `layersGetVtx()`
  db.layersGetVtx(vid).valueOr: VertexRef(nil)


func layersGetKey*(db: AristoDbRef; vid: VertexID): Opt[HashKey] =
  ## Find a hash key on the cache layers. An `ok()` result might contain a void
  ## hash key if it is stored on the cache that way.
  ##
  db.top.delta.kMap.withValue(vid, item):
    return Opt.some(item[])

  for w in db.rstack:
    w.delta.kMap.withValue(vid, item):
      return ok(item[])

  Opt.none(HashKey)

func layersGetKeyOrVoid*(db: AristoDbRef; vid: VertexID): HashKey =
  ## Simplified version of `layersGetKey()`
  db.layersGetKey(vid).valueOr: VOID_HASH_KEY

func layersGetStoID*(db: AristoDbRef; accPath: Hash256): Opt[VertexID] =
  db.top.delta.accSids.withValue(accPath, item):
    return Opt.some(item[])

  for w in db.rstack:
    w.delta.accSids.withValue(accPath, item):
      return Opt.some(item[])

  Opt.none(VertexID)

# ------------------------------------------------------------------------------
# Public functions: setter variants
# ------------------------------------------------------------------------------

func layersPutVtx*(
    db: AristoDbRef;
    root: VertexID;
    vid: VertexID;
    vtx: VertexRef;
      ) =
  ## Store a (potentally empty) vertex on the top layer
  db.top.delta.sTab[vid] = vtx

func layersResVtx*(
    db: AristoDbRef;
    root: VertexID;
    vid: VertexID;
      ) =
  ## Shortcut for `db.layersPutVtx(vid, VertexRef(nil))`. It is sort of the
  ## equivalent of a delete function.
  db.layersPutVtx(root, vid, VertexRef(nil))


func layersPutKey*(
    db: AristoDbRef;
    root: VertexID;
    vid: VertexID;
    key: HashKey;
      ) =
  ## Store a (potentally void) hash key on the top layer
  db.top.delta.kMap[vid] = key


func layersResKey*(db: AristoDbRef; root: VertexID; vid: VertexID) =
  ## Shortcut for `db.layersPutKey(vid, VOID_HASH_KEY)`. It is sort of the
  ## equivalent of a delete function.
  db.layersPutKey(root, vid, VOID_HASH_KEY)

func layersPutStoID*(db: AristoDbRef; accPath: Hash256; stoID: VertexID) =
  db.top.delta.accSids[accPath] = stoID

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func layersMergeOnto*(src: LayerRef; trg: var LayerObj) =
  ## Merges the argument `src` into the argument `trg` and returns `trg`. For
  ## the result layer, the `txUid` value set to `0`.
  ##
  trg.txUid = 0

  for (vid,vtx) in src.delta.sTab.pairs:
    trg.delta.sTab[vid] = vtx
  for (vid,key) in src.delta.kMap.pairs:
    trg.delta.kMap[vid] = key
  trg.delta.vTop = src.delta.vTop
  for (accPath,stoID) in src.delta.accSids.pairs:
    trg.delta.accSids[accPath] = stoID

func layersCc*(db: AristoDbRef; level = high(int)): LayerRef =
  ## Provide a collapsed copy of layers up to a particular transaction level.
  ## If the `level` argument is too large, the maximum transaction level is
  ## returned. For the result layer, the `txUid` value set to `0`.
  ##
  let layers = if db.stack.len <= level: db.stack & @[db.top]
               else:                     db.stack[0 .. level]

  # Set up initial layer (bottom layer)
  result = LayerRef(
    delta: LayerDeltaRef(
      sTab: layers[0].delta.sTab.dup,          # explicit dup for ref values
      kMap: layers[0].delta.kMap,
      vTop: layers[^1].delta.vTop,
      accSids: layers[0].delta.accSids,
      ))

  # Consecutively merge other layers on top
  for n in 1 ..< layers.len:
    for (vid,vtx) in layers[n].delta.sTab.pairs:
      result.delta.sTab[vid] = vtx
    for (vid,key) in layers[n].delta.kMap.pairs:
      result.delta.kMap[vid] = key
    for (accPath,stoID) in layers[n].delta.accSids.pairs:
      result.delta.accSids[accPath] = stoID

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator layersWalkVtx*(
    db: AristoDbRef;
    seen: var HashSet[VertexID];
      ): tuple[vid: VertexID, vtx: VertexRef] =
  ## Walk over all `(VertexID,VertexRef)` pairs on the cache layers. Note that
  ## entries are unsorted.
  ##
  ## The argument `seen` collects a set of all visited vertex IDs including
  ## the one with a zero vertex which are othewise skipped by the iterator.
  ## The `seen` argument must not be modified while the iterator is active.
  ##
  for (vid,vtx) in db.top.delta.sTab.pairs:
    yield (vid,vtx)
    seen.incl vid

  for w in db.rstack:
    for (vid,vtx) in w.delta.sTab.pairs:
      if vid notin seen:
        yield (vid,vtx)
        seen.incl vid

iterator layersWalkVtx*(
    db: AristoDbRef;
      ): tuple[vid: VertexID, vtx: VertexRef] =
  ## Variant of `layersWalkVtx()`.
  var seen: HashSet[VertexID]
  for (vid,vtx) in db.layersWalkVtx seen:
    yield (vid,vtx)


iterator layersWalkKey*(
    db: AristoDbRef;
      ): tuple[vid: VertexID, key: HashKey] =
  ## Walk over all `(VertexID,HashKey)` pairs on the cache layers. Note that
  ## entries are unsorted.
  var seen: HashSet[VertexID]
  for (vid,key) in db.top.delta.kMap.pairs:
    yield (vid,key)
    seen.incl vid

  for w in db.rstack:
    for (vid,key) in w.delta.kMap.pairs:
      if vid notin seen:
        yield (vid,key)
        seen.incl vid

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
