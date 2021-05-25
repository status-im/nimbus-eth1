# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Hash as hash can: LRU cache
## ===========================
##
## This module provides a generic last-recently-used cache data structure.
##
## The implementation works with the same complexity as the worst case of a
## nim hash tables operation. This is is assumed to be O(1) in most cases
## (so long as the table does not degrade into one-bucket linear mode, or
## some bucket-adjustment algorithm takes over.)
##

import
  math,
  eth/rlp,
  stew/results,
  tables

export
  results

type
  LruKey*[T,K] =                  ## User provided handler function, derives an
                                  ## LRU `key` from function argument `arg`. The
                                  ## `key` is used to index the cache data.
    proc(arg: T): K {.gcsafe, raises: [Defect,CatchableError].}

  LruValue*[T,V,E] =              ## User provided handler function, derives an
                                  ## LRU `value` from function argument `arg`.
    proc(arg: T): Result[V,E] {.gcsafe, raises: [Defect,CatchableError].}

  LruItem*[K,V] =                 ## Doubly linked hash-tab item encapsulating
                                  ## the `value` (which is the result from
                                  ## `LruValue` handler function.
    tuple[prv, nxt: K, value: V]

  # There could be {.rlpCustomSerialization.} annotation for the tab field.
  # As there was a problem with the automatic Rlp serialisation for generic
  # type, the easier solution was an all manual read()/append() for the whole
  # generic LruCacheData[K,V] type.
  LruData[K,V] = object
    maxItems: int                 ## Max number of entries
    first, last: K                ## Doubly linked item list queue
    tab: TableRef[K,LruItem[K,V]] ## (`key`,encapsulated(`value`)) data table

  LruCache*[T,K,V,E] = object
    data*: LruData[K,V]           ## Cache data, can be serialised
    toKey: LruKey[T,K]            ## Handler function, derives `key`
    toValue: LruValue[T,V,E]      ## Handler function, derives `value`

{.push raises: [Defect,CatchableError].}

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc `==`[K,V](a, b: var LruData[K,V]): bool =
  a.maxItems == b.maxItems and
    a.first == b.first and
    a.last == b.last and
    a.tab == b.tab

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc clearLruCache*[T,K,V,E](cache: var LruCache[T,K,V,E])
                                          {.gcsafe, raises: [Defect].} =
  ## Reset/clear an initialised LRU cache.
  cache.data.first.reset
  cache.data.last.reset
  cache.data.tab = newTable[K,LruItem[K,V]](cache.data.maxItems.nextPowerOfTwo)


proc initLruCache*[T,K,V,E](cache: var LruCache[T,K,V,E];
                            toKey: LruKey[T,K], toValue: LruValue[T,V,E];
                            cacheMaxItems = 10) {.gcsafe, raises: [Defect].} =
  ## Initialise LRU cache. The handlers `toKey()` and `toValue()` are
  ## explained at the data type definition.
  cache.data.maxItems = cacheMaxItems
  cache.toKey = toKey
  cache.toValue = toValue
  cache.clearLruCache


proc getLruItem*[T,K,V,E](lru: var LruCache[T,K,V,E];
                             arg: T): Result[V,E] {.gcsafe.} =
  ## Returns `lru.toValue(arg)`, preferably from result cached earlier.
  let key = lru.toKey(arg)

  # Relink item if already in the cache => move to last position
  if lru.data.tab.hasKey(key):
    let lruItem = lru.data.tab[key]

    if key == lru.data.last:
      # Nothing to do
      return ok(lruItem.value)

    # Unlink key Item
    if key == lru.data.first:
      lru.data.first = lruItem.nxt
    else:
      lru.data.tab[lruItem.prv].nxt = lruItem.nxt
      lru.data.tab[lruItem.nxt].prv = lruItem.prv

    # Append key item
    lru.data.tab[lru.data.last].nxt = key
    lru.data.tab[key].prv = lru.data.last
    lru.data.last = key
    return ok(lruItem.value)

  # Calculate value, pass through error unless OK
  let rcValue = ? lru.toValue(arg)

  # Limit number of cached items
  if lru.data.maxItems <= lru.data.tab.len:
    # Delete oldest/first entry
    var nextKey = lru.data.tab[lru.data.first].nxt
    lru.data.tab.del(lru.data.first)
    lru.data.first = nextKey

  # Add cache entry
  var tabItem: LruItem[K,V]

  # Initialise empty queue
  if lru.data.tab.len == 0:
    lru.data.first = key
    lru.data.last = key
  else:
    # Append queue item
    lru.data.tab[lru.data.last].nxt = key
    tabItem.prv = lru.data.last
    lru.data.last = key

  tabItem.value = rcValue
  lru.data.tab[key] = tabItem
  result = ok(rcValue)


proc `==`*[T,K,V,E](a, b: var LruCache[T,K,V,E]): bool =
  ## Returns `true` if both argument LRU caches contain the same data
  ## regardless of `toKey()`/`toValue()` handler functions.
  a.data == b.data


proc append*[K,V](rw: var RlpWriter; data: LruData[K,V]) {.inline.} =
  ## Generic support for `rlp.encode(lru.data)` for serialising the data
  ## part of an LRU cache.
  rw.append(data.maxItems)
  rw.append(data.first)
  rw.append(data.last)
  rw.startList(data.tab.len)
  # store keys in LRU order
  if 0 < data.tab.len:
    var key = data.first
    for _ in 0 ..< data.tab.len - 1:
      var value = data.tab[key]
      rw.append((key, value))
      key = value.nxt
    rw.append((key, data.tab[key]))
    if key != data.last:
      raiseAssert "Garbled LRU cache next/prv references"

proc read*[K,V](rlp: var Rlp; Q: type LruData[K,V]): Q {.inline.} =
  ## Generic support for `rlp.decode(bytes)` for loading the data part
  ## of an LRU cache from a serialised data stream.
  result.maxItems = rlp.read(int)
  result.first = rlp.read(K)
  result.last = rlp.read(K)
  result.tab = newTable[K,LruItem[K,V]](result.maxItems.nextPowerOfTwo)
  for w in rlp.items:
    let (key,value) = w.read((K,LruItem[K,V]))
    result.tab[key] = value


proc specs*[T,K,V,E](cache: var LruCache[T,K,V,E]):
                                  (int, K, K, TableRef[K,LruItem[K,V]]) =
  ## Returns cache data & specs `(maxItems,firstKey,lastKey,tableRef)` for
  ## debugging and testing.
  (cache.data.maxItems, cache.data.first, cache.data.last, cache.data.tab)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
