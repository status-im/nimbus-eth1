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
  std/[algorithm, sequtils, sets, tables],
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

func getLebalOrVoid(stack: seq[LayerRef]; key: HashKey): HashSet[VertexID] =
  # Helper: get next set of vertex IDs from stack.
  for w in stack.reversed:
    w.delta.pAmk.withValue(key,value):
      return value[]

proc recalcLebal(layer: var LayerObj) =
  ## Calculate reverse `kMap[]` for final (aka zero) layer
  layer.delta.pAmk.clear
  for (vid,key) in layer.delta.kMap.pairs:
    if key.isValid:
      layer.delta.pAmk.withValue(key, value):
        value[].incl vid
      do:
        layer.delta.pAmk[key] = @[vid].toHashSet

# ------------------------------------------------------------------------------
# Public getters: lazy value lookup for read only versions
# ------------------------------------------------------------------------------

func lTab*(db: AristoDbRef): Table[LeafTie,VertexID] =
  db.top.final.lTab

func pPrf*(db: AristoDbRef): HashSet[VertexID] =
  db.top.final.pPrf

func vGen*(db: AristoDbRef): seq[VertexID] =
  db.top.final.vGen

func dirty*(db: AristoDbRef): bool =
  db.top.final.dirty

# ------------------------------------------------------------------------------
# Public getters/helpers
# ------------------------------------------------------------------------------

func nLayersVtx*(db: AristoDbRef): int =
  ## Number of vertex ID/vertex entries on the cache layers. This is an upper bound
  ## for the number of effective vertex ID mappings held on the cache layers as
  ## there might be duplicate entries for the same vertex ID on different layers.
  ##
  db.stack.mapIt(it.delta.sTab.len).foldl(a + b, db.top.delta.sTab.len)

func nLayersKey*(db: AristoDbRef): int =
  ## Number of vertex ID/key entries on the cache layers. This is an upper bound
  ## for the number of effective vertex ID mappingss held on the cache layers as
  ## there might be duplicate entries for the same vertex ID on different layers.
  ##
  db.stack.mapIt(it.delta.kMap.len).foldl(a + b, db.top.delta.kMap.len)

func nLayersYek*(db: AristoDbRef): int =
  ## Number of key/vertex IDs reverse lookup entries on the cache layers. This
  ## is an upper bound for the number of effective key mappingss held on the
  ## cache layers as there might be duplicate entries for the same key on
  ## different layers.
  ##
  db.stack.mapIt(it.delta.pAmk.len).foldl(a + b, db.top.delta.pAmk.len)

# ------------------------------------------------------------------------------
# Public functions: get variants
# ------------------------------------------------------------------------------

proc layersGetVtx*(db: AristoDbRef; vid: VertexID): Result[VertexRef,void] =
  ## Find a vertex on the cache layers. An `ok()` result might contain a
  ## `nil` vertex if it is stored on the cache  that way.
  ##
  if db.top.delta.sTab.hasKey vid:
    return ok(db.top.delta.sTab.getOrVoid vid)

  for w in db.stack.reversed:
    if w.delta.sTab.hasKey vid:
      return ok(w.delta.sTab.getOrVoid vid)

  err()

proc layersGetVtxOrVoid*(db: AristoDbRef; vid: VertexID): VertexRef =
  ## Simplified version of `layersGetVtx()`
  db.layersGetVtx(vid).valueOr: VertexRef(nil)


proc layersGetKey*(db: AristoDbRef; vid: VertexID): Result[HashKey,void] =
  ## Find a hash key on the cache layers. An `ok()` result might contain a void
  ## hash key if it is stored on the cache that way.
  ##
  if db.top.delta.kMap.hasKey vid:
    # This is ok regardless of the `dirty` flag. If this vertex has become
    # dirty, there is an empty `kMap[]` entry on this layer.
    return ok(db.top.delta.kMap.getOrVoid vid)

  for w in db.stack.reversed:
    if w.delta.kMap.hasKey vid:
      # Same reasoning as above regarding the `dirty` flag.
      return ok(w.delta.kMap.getOrVoid vid)

  err()

proc layersGetKeyOrVoid*(db: AristoDbRef; vid: VertexID): HashKey =
  ## Simplified version of `layersGetkey()`
  db.layersGetKey(vid).valueOr: VOID_HASH_KEY


proc layersGetYek*(
    db: AristoDbRef;
    key: HashKey;
      ): Result[HashSet[VertexID],void] =
  ## Inverse of `layersGetKey()`. For a given argumnt `key`, finds all vertex IDs
  ## that have `layersGetKey()` return this very `key` value for the argument
  ## vertex IDs.
  if db.top.delta.pAmk.hasKey key:
    return ok(db.top.delta.pAmk.getOrVoid key)

  for w in db.stack.reversed:
    if w.delta.pAmk.hasKey key:
      return ok(w.delta.pAmk.getOrVoid key)

  err()

proc layersGetYekOrVoid*(db: AristoDbRef; key: HashKey): HashSet[VertexID] =
  ## Simplified version of `layersGetVidsOrVoid()`
  db.layersGetYek(key).valueOr: EmptyVidSet

# ------------------------------------------------------------------------------
# Public functions: put variants
# ------------------------------------------------------------------------------

proc layersPutVtx*(db: AristoDbRef; vid: VertexID; vtx: VertexRef) =
  ## Store a (potentally empty) vertex on the top layer
  db.top.delta.sTab[vid] = vtx
  db.top.final.dirty = true # Modified top cache layers

proc layersResVtx*(db: AristoDbRef; vid: VertexID) =
  ## Shortcut for `db.layersPutVtx(vid, VertexRef(nil))`. It is sort of the
  ## equivalent of a delete function.
  db.layersPutVtx(vid, VertexRef(nil))


proc layersPutKey*(db: AristoDbRef; vid: VertexID; key: HashKey) =
  ## Store a (potentally void) hash key on the top layer

  # Get previous key
  let prvKey = db.top.delta.kMap.getOrVoid vid
    
  # Update key on `kMap:key->vid` mapping table
  db.top.delta.kMap[vid] = key
  db.top.final.dirty = true # Modified top cache layers

  # Clear previous value on reverse table if it has changed
  if prvKey.isValid and prvKey != key:
    var vidsLen = -1
    db.top.delta.pAmk.withValue(prvKey, value):
      value[].excl vid
      vidsLen = value[].len
    do: # provide empty lookup
      let vids = db.stack.getLebalOrVoid(prvKey)
      if vids.isValid and vid in vids:
        # This entry supersedes non-emtpty changed ones from lower levels
        db.top.delta.pAmk[prvKey] = vids - @[vid].toHashSet
    if vidsLen == 0 and not db.stack.getLebalOrVoid(prvKey).isValid:
      # There is no non-emtpty entry on lower levels, so ledete this one
      db.top.delta.pAmk.del prvKey

  # Add updated value on reverse table if non-zero
  if key.isValid:
    db.top.delta.pAmk.withValue(key, value):
      value[].incl vid
    do: # else if not found: need to merge with value set from lower layer
      db.top.delta.pAmk[key] = db.stack.getLebalOrVoid(key) + @[vid].toHashSet


proc layersResKey*(db: AristoDbRef; vid: VertexID) =
  ## Shortcut for `db.layersPutKey(vid, VOID_HASH_KEY)`. It is sort of the
  ## equivalent of a delete function.
  db.layersPutKey(vid, VOID_HASH_KEY)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc layersMergeOnto*(src: LayerRef; trg: var LayerObj; stack: seq[LayerRef]) =
  ## Merges the argument `src` into the argument `trg` and returns `trg`. For
  ## the result layer, the `txUid` value set to `0`.
  ##
  trg.final = src.final
  trg.txUid = 0

  for (vid,vtx) in src.delta.sTab.pairs:
    trg.delta.sTab[vid] = vtx
  for (vid,key) in src.delta.kMap.pairs:
    trg.delta.kMap[vid] = key

  if stack.len == 0:
    # Re-calculate `pAmk[]`
    trg.recalcLebal()
  else:
    # Merge reverse `kMap[]` layers. Empty key set images are ignored unless
    # they supersede non-empty values on the argument `stack[]`.
    for (key,vids) in src.delta.pAmk.pairs:
      if 0 < vids.len or stack.getLebalOrVoid(key).isValid:
        trg.delta.pAmk[key] = vids


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

  # Re-calculate `pAmk[]`
  result[].recalcLebal()

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

  for w in db.stack.reversed:
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

  for w in db.stack.reversed:
    for (vid,key) in w.delta.kMap.pairs:
      if vid notin seen:
        yield (vid,key)
        seen.incl vid


iterator layersWalkYek*(
    db: AristoDbRef;
      ): tuple[key: HashKey, vids: HashSet[VertexID]] =
  ## Walk over `(HashKey,HashSet[VertexID])` pairs.
  var seen: HashSet[HashKey]
  for (key,vids) in db.top.delta.pAmk.pairs:
    yield (key,vids)
    seen.incl key

  for w in db.stack.reversed:
    for  (key,vids) in w.delta.pAmk.pairs:
      if key notin seen:
        yield (key,vids)
        seen.incl key

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
