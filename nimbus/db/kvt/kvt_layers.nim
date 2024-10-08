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
  ./kvt_desc

# ------------------------------------------------------------------------------
# Public getters/helpers
# ------------------------------------------------------------------------------

func nLayersKeys*(db: KvtDbRef): int =
  ## Maximum number of ley/value entries on the cache layers. This is an upper
  ## bound for the number of effective key/value mappings held on the cache
  ## layers as there might be duplicate entries for the same key on different
  ## layers.
  db.stack.mapIt(it.sTab.len).foldl(a + b, db.top.sTab.len)

# ------------------------------------------------------------------------------
# Public functions: get function
# ------------------------------------------------------------------------------

func layersLen*(db: KvtDbRef; key: openArray[byte]|seq[byte]): Opt[int] =
  ## Returns the size of the value associated with `key`.
  ##
  when key isnot seq[byte]:
    let key = @key

  db.top.sTab.withValue(key, item):
    return Opt.some(item[].len())

  for w in db.rstack:
    w.sTab.withValue(key, item):
      return Opt.some(item[].len())

  Opt.none(int)

func layersHasKey*(db: KvtDbRef; key: openArray[byte]|seq[byte]): bool =
  ## Return `true` if the argument key is cached.
  ##
  db.layersLen(key).isSome()

func layersGet*(db: KvtDbRef; key: openArray[byte]|seq[byte]): Opt[seq[byte]] =
  ## Find an item on the cache layers. An `ok()` result might contain an
  ## empty value if it is stored on the cache  that way.
  ##
  when key isnot seq[byte]:
    let key = @key

  db.top.sTab.withValue(key, item):
    return Opt.some(item[])

  for w in db.rstack:
    w.sTab.withValue(key, item):
      return Opt.some(item[])

  Opt.none(seq[byte])

# ------------------------------------------------------------------------------
# Public functions: put function
# ------------------------------------------------------------------------------

func layersPut*(db: KvtDbRef; key: openArray[byte]; data: openArray[byte]) =
  ## Store a (potentally empty) value on the top layer
  db.top.sTab[@key] = @data

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func layersCc*(db: KvtDbRef; level = high(int)): LayerRef =
  ## Provide a collapsed copy of layers up to a particular transaction level.
  ## If the `level` argument is too large, the maximum transaction level is
  ## returned. For the result layer, the `txUid` value set to `0`.
  let layers = if db.stack.len <= level: db.stack & @[db.top]
               else:                     db.stack[0 .. level]

  # Set up initial layer (bottom layer)
  result = LayerRef(sTab: layers[0].sTab)

  # Consecutively merge other layers on top
  for n in 1 ..< layers.len:
    for (key,val) in layers[n].sTab.pairs:
      result.sTab[key] = val

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator layersWalk*(
    db: KvtDbRef;
    seen: var HashSet[seq[byte]];
      ): tuple[key: seq[byte], data: seq[byte]] =
  ## Walk over all key-value pairs on the cache layers. Note that
  ## entries are unsorted.
  ##
  ## The argument `seen` collects a set of all visited vertex IDs including
  ## the one with a zero vertex which are othewise skipped by the iterator.
  ## The `seen` argument must not be modified while the iterator is active.
  ##
  for (key,val) in db.top.sTab.pairs:
    yield (key,val)
    seen.incl key

  for w in db.rstack:
    for (key,val) in w.sTab.pairs:
      if key notin seen:
        yield (key,val)
        seen.incl key

iterator layersWalk*(
    db: KvtDbRef;
      ): tuple[key: seq[byte], data: seq[byte]] =
  ## Variant of `layersWalk()`.
  var seen: HashSet[seq[byte]]
  for (key,val) in db.layersWalk seen:
    yield (key,val)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
