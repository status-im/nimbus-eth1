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
## For consistency with every other data type in Nim these have value
## semantics, this means that `=` performs a deep copy of the LRU cache.
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
    tab: Table[K,LruItem[K,V]]    ## (`key`,encapsulated(`value`)) data table

  LruCache*[T,K,V,E] = object
    data*: LruData[K,V]           ## Cache data, can be serialised
    toKey: LruKey[T,K]            ## Handler function, derives `key`
    toValue: LruValue[T,V,E]      ## Handler function, derives `value`

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc `==`[K,V](a, b: var LruData[K,V]): bool =
  a.maxItems == b.maxItems and
    a.first == b.first and
    a.last == b.last and
    a.tab == b.tab

# ------------------------------------------------------------------------------
# Public constructor and reset
# ------------------------------------------------------------------------------

proc clearCache*[T,K,V,E](cache: var LruCache[T,K,V,E]; cacheInitSize = 0)
                                                {.gcsafe, raises: [Defect].} =
  ## Reset/clear an initialised LRU cache. The cache will be re-allocated
  ## with `cacheInitSize` initial spaces if this is positive, or `cacheMaxItems`
  ## spaces (see `initLruCache()`) as a default.
  var initSize = cacheInitSize
  if initSize <= 0:
    initSize = cache.data.maxItems
  cache.data.first.reset
  cache.data.last.reset
  cache.data.tab = initTable[K,LruItem[K,V]](initSize.nextPowerOfTwo)


proc initCache*[T,K,V,E](cache: var LruCache[T,K,V,E];
                         toKey: LruKey[T,K], toValue: LruValue[T,V,E];
                         cacheMaxItems = 10; cacheInitSize = 0)
                                                {.gcsafe, raises: [Defect].} =
  ## Initialise LRU cache. The handlers `toKey()` and `toValue()` are explained
  ## at the data type definition. The cache will be allocated with
  ## `cacheInitSize` initial spaces if this is positive, or `cacheMaxItems`
  ## spaces (see `initLruCache()`) as a default.
  cache.data.maxItems = cacheMaxItems
  cache.toKey = toKey
  cache.toValue = toValue
  cache.clearCache

# ------------------------------------------------------------------------------
# Public functions, basic mechanism
# ------------------------------------------------------------------------------

proc getItem*[T,K,V,E](lru: var LruCache[T,K,V,E];
                       arg: T; peekOk = false): Result[V,E]
                       {.gcsafe, raises: [Defect,CatchableError].} =
  ## If the key `lru.toKey(arg)` is a cached key, the associated value will
  ## be returnd. If the `peekOK` argument equals `false`, the associated
  ## key-value pair will have been moved to the end of the LRU queue.
  ##
  ## If the key `lru.toKey(arg)` is not a cached key and the LRU queue has at
  ## least `cacheMaxItems` entries (see `initLruCache()`, the first key-value
  ## pair will be removed from the LRU queue. Then the value the pair
  ## (`lru.toKey(arg)`,`lru.toValue(arg)`) will be appended to the LRU queue
  ## and the value part returned.
  ##
  let key = lru.toKey(arg)

  # Relink item if already in the cache => move to last position
  if lru.data.tab.hasKey(key):
    let lruItem = lru.data.tab[key]

    if peekOk or key == lru.data.last:
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

# ------------------------------------------------------------------------------
# Public functions, cache info
# ------------------------------------------------------------------------------

proc hasKey*[T,K,V,E](lru: var LruCache[T,K,V,E]; arg: T): bool {.gcsafe.} =
  ## Check whether the `arg` argument is cached
  let key = lru.toKey(arg)
  lru.data.tab.hasKey(key)

proc firstKey*[T,K,V,E](lru: var LruCache[T,K,V,E]): K {.gcsafe.} =
  ## Returns the key of the first item in the LRU queue, or the reset
  ## value it the cache is empty.
  if 0 < lru.data.tab.len:
    result = lru.data.first

proc lastKey*[T,K,V,E](lru: var LruCache[T,K,V,E]): K {.gcsafe.} =
  ## Returns the key of the last item in the LRU queue, or the reset
  ## value it the cache is empty.
  if 0 < lru.data.tab.len:
    result = lru.data.last


proc maxLen*[T,K,V,E](lru: var LruCache[T,K,V,E]): int {.gcsafe.} =
  ## Maximal number of cache entries.
  lru.data.maxItems

proc len*[T,K,V,E](lru: var LruCache[T,K,V,E]): int {.gcsafe.} =
  ## Return the number of elements in the cache.
  lru.data.tab.len

# ------------------------------------------------------------------------------
# Public functions, advanced features
# ------------------------------------------------------------------------------

proc setItem*[T,K,V,E](lru: var LruCache[T,K,V,E]; arg: T; value: V): bool
                    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Update entry with key `lru.toKey(arg)` by `value`. Reurns `true` if the
  ## key exists in the database, and false otherwise.
  ##
  ## This function allows for simlifying the `toValue()` function (see
  ## `initLruCache()`) to provide a placeholder only and later fill this
  ## slot with this `setLruItem()` function.
  let key = lru.toKey(arg)
  if lru.data.tab.hasKey(key):
    lru.data.tab[key].value = value
    return true


proc delItem*[T,K,V,E](lru: var LruCache[T,K,V,E]; arg: T): bool
                     {.gcsafe, discardable, raises: [Defect,KeyError].} =
  ## Delete the `arg` argument from cached. That way, the LRU cache can
  ## be re-purposed as a sequence with efficient random delete facility.
  let key = lru.toKey(arg)

  # Relink item if already in the cache => move to last position
  if lru.data.tab.hasKey(key):
    let lruItem = lru.data.tab[key]

    # Unlink key Item
    if lru.data.tab.len == 1:
      lru.data.first.reset
      lru.data.last.reset
    elif key == lru.data.last:
      lru.data.last = lruItem.prv
    elif key == lru.data.first:
      lru.data.first = lruItem.nxt
    else:
      lru.data.tab[lruItem.prv].nxt = lruItem.nxt
      lru.data.tab[lruItem.nxt].prv = lruItem.prv

    lru.data.tab.del(key)
    return true


iterator keyItemPairs*[T,K,V,E](lru: var LruCache[T,K,V,E]): (K,LruItem[K,V])
                                {.gcsafe, raises: [Defect,CatchableError].} =
  ## Cycle through all (key,lruItem) pairs in chronological order.
  if 0 < lru.data.tab.len:
    var key = lru.data.first
    for _ in 0 ..< lru.data.tab.len - 1:
      var item = lru.data.tab[key]
      yield (key, item)
      key = item.nxt
    yield (key, lru.data.tab[key])
    if key != lru.data.last:
      raiseAssert "Garbled LRU cache next/prv references"

# ------------------------------------------------------------------------------
# Public functions, RLP support
# ------------------------------------------------------------------------------

proc `==`*[T,K,V,E](a, b: var LruCache[T,K,V,E]): bool =
  ## Returns `true` if both argument LRU caches contain the same data
  ## regardless of `toKey()`/`toValue()` handler functions.
  a.data == b.data


proc append*[K,V](rw: var RlpWriter; data: LruData[K,V]) {.
                  inline, raises: [Defect,KeyError].} =
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

proc read*[K,V](rlp: var Rlp; Q: type LruData[K,V]): Q {.
                inline, raises: [Defect,RlpError].} =
  ## Generic support for `rlp.decode(bytes)` for loading the data part
  ## of an LRU cache from a serialised data stream.
  result.maxItems = rlp.read(int)
  result.first = rlp.read(K)
  result.last = rlp.read(K)
  for w in rlp.items:
    let (key,value) = w.read((K,LruItem[K,V]))
    result.tab[key] = value

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
