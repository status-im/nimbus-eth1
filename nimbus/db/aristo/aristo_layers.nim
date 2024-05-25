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

func dirty*(db: AristoDbRef): lent HashSet[VertexID] =
  db.top.final.dirty

func pPrf*(db: AristoDbRef): lent HashSet[VertexID] =
  db.top.final.pPrf

func vGen*(db: AristoDbRef): lent seq[VertexID] =
  db.top.final.vGen

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

func layersGetVtx*(db: AristoDbRef; vid: VertexID): Result[VertexRef,void] =
  ## Find a vertex on the cache layers. An `ok()` result might contain a
  ## `nil` vertex if it is stored on the cache  that way.
  ##
  if db.top.delta.sTab.hasKey vid:
    return ok(db.top.delta.sTab.getOrVoid vid)

  for w in db.rstack:
    if w.delta.sTab.hasKey vid:
      return ok(w.delta.sTab.getOrVoid vid)

  err()

func layersGetVtxOrVoid*(db: AristoDbRef; vid: VertexID): VertexRef =
  ## Simplified version of `layersGetVtx()`
  db.layersGetVtx(vid).valueOr: VertexRef(nil)


func layersGetKey*(db: AristoDbRef; vid: VertexID): Result[HashKey,void] =
  ## Find a hash key on the cache layers. An `ok()` result might contain a void
  ## hash key if it is stored on the cache that way.
  ##
  if db.top.delta.kMap.hasKey vid:
    # This is ok regardless of the `dirty` flag. If this vertex has become
    # dirty, there is an empty `kMap[]` entry on this layer.
    return ok(db.top.delta.kMap.getOrVoid vid)

  for w in db.rstack:
    if w.delta.kMap.hasKey vid:
      # Same reasoning as above regarding the `dirty` flag.
      return ok(w.delta.kMap.getOrVoid vid)

  err()

func layersGetKeyOrVoid*(db: AristoDbRef; vid: VertexID): HashKey =
  ## Simplified version of `layersGetkey()`
  db.layersGetKey(vid).valueOr: VOID_HASH_KEY


func layerGetProofKeyOrVoid*(db: AristoDbRef; vid: VertexID): HashKey =
  ## Get the hash key of a proof node if it was registered as such.
  if vid in db.top.final.pPrf:
    db.top.delta.kMap.getOrVoid vid
  else:
    VOID_HASH_KEY

func layerGetProofVidOrVoid*(db: AristoDbRef; key: HashKey): VertexID =
  ## Reverse look up for a registered proof node or a link key for such a
  ## node. The vertex for a returned vertex ID might not exist if the
  ## argument `key` refers to a link key of a registered proof node.
  db.top.final.fRpp.getOrVoid key

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
  db.top.final.dirty.incl root

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
  db.top.final.dirty.incl root # Modified top cache layers => hashify


func layersResKey*(db: AristoDbRef; root: VertexID; vid: VertexID) =
  ## Shortcut for `db.layersPutKey(vid, VOID_HASH_KEY)`. It is sort of the
  ## equivalent of a delete function.
  db.layersPutKey(root, vid, VOID_HASH_KEY)


func layersPutProof*(db: AristoDbRef; vid: VertexID; key: HashKey) =
  ## Register a link key of a proof node.
  let lKey = db.layersGetKeyOrVoid vid
  if not lKey.isValid or lKey != key:
    db.top.delta.kMap[vid] = key
  db.top.final.fRpp[key] = vid

func layersPutProof*(
    db: AristoDbRef;
    vid: VertexID;
    key: HashKey;
    vtx: VertexRef;
      ) =
  ## Register a full proof node (not only a link key.)
  let lVtx = db.layersGetVtxOrVoid vid
  if not lVtx.isValid or lVtx != vtx:
    db.top.delta.sTab[vid] = vtx
  db.top.final.pPrf.incl vid
  db.layersPutProof(vid, key)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func layersMergeOnto*(src: LayerRef; trg: var LayerObj) =
  ## Merges the argument `src` into the argument `trg` and returns `trg`. For
  ## the result layer, the `txUid` value set to `0`.
  ##
  trg.final = src.final
  trg.txUid = 0

  for (vid,vtx) in src.delta.sTab.pairs:
    trg.delta.sTab[vid] = vtx
  for (vid,key) in src.delta.kMap.pairs:
    trg.delta.kMap[vid] = key


func layersCc*(db: AristoDbRef; level = high(int)): LayerRef =
  ## Provide a collapsed copy of layers up to a particular transaction level.
  ## If the `level` argument is too large, the maximum transaction level is
  ## returned. For the result layer, the `txUid` value set to `0`.
  ##
  let layers = if db.stack.len <= level: db.stack & @[db.top]
               else:                     db.stack[0 .. level]

  # Set up initial layer (bottom layer)
  result = LayerRef(
    final: layers[^1].final.dup,               # Pre-merged/final values
    delta: LayerDeltaRef(
      sTab: layers[0].delta.sTab.dup,          # explicit dup for ref values
      kMap: layers[0].delta.kMap))

  # Consecutively merge other layers on top
  for n in 1 ..< layers.len:
    for (vid,vtx) in layers[n].delta.sTab.pairs:
      result.delta.sTab[vid] = vtx
    for (vid,key) in layers[n].delta.kMap.pairs:
      result.delta.kMap[vid] = key

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
