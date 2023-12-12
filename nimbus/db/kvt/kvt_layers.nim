# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
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
  ./kvt_desc

# ------------------------------------------------------------------------------
# Public getters/helpers
# ------------------------------------------------------------------------------

func nLayersKeys*(db: KvtDbRef): int =
  ## Number of vertex entries on the cache layers
  db.stack.mapIt(it.delta.sTab.len).foldl(a + b, db.top.delta.sTab.len)

# ------------------------------------------------------------------------------
# Public functions: get function
# ------------------------------------------------------------------------------

proc layersHasKey*(db: KvtDbRef; key: openArray[byte]): bool =
  ## Return `true` id the argument key is cached.
  ##
  if db.top.delta.sTab.hasKey @key:
    return true

  for w in db.stack.reversed:
    if w.delta.sTab.hasKey @key:
      return true


proc layersGet*(db: KvtDbRef; key: openArray[byte]): Result[Blob,void] =
  ## Find an item on the cache layers. An `ok()` result might contain an
  ## empty value if it is stored on the cache  that way.
  ##
  if db.top.delta.sTab.hasKey @key:
    return ok(db.top.delta.sTab.getOrVoid @key)

  for w in db.stack.reversed:
    if w.delta.sTab.hasKey @key:
      return ok(w.delta.sTab.getOrVoid @key)

  err()

# ------------------------------------------------------------------------------
# Public functions: put function
# ------------------------------------------------------------------------------

proc layersPut*(db: KvtDbRef; key: openArray[byte]; data: openArray[byte]) =
  ## Store a (potentally empty) value on the top layer
  db.top.delta.sTab[@key] = @data

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc layersCc*(db: KvtDbRef; level = high(int)): LayerRef =
  ## Provide a collapsed copy of layers up to a particular transaction level.
  ## If the `level` argument is too large, the maximum transaction level is
  ## returned. For the result layer, the `txUid` value set to `0`.
  let level = min(level, db.stack.len)

  # Merge stack into its bottom layer
  if level <= 0 and db.stack.len == 0:
    result = LayerRef(delta: LayerDelta(sTab: db.top.delta.sTab))
  else:
    # now: 0 < level <= db.stack.len
    result = LayerRef(delta: LayerDelta(sTab: db.stack[0].delta.sTab))

    for n in 1 ..< level:
      for (key,val) in db.stack[n].delta.sTab.pairs:
        result.delta.sTab[key] = val

    # Merge top layer if needed
    if level == db.stack.len:
      for (key,val) in db.top.delta.sTab.pairs:
        result.delta.sTab[key] = val

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
