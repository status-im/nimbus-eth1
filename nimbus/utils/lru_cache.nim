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
## Provide last-recently-used cache data structure. The implementation works
## with the same complexity as the worst case of a nim hash tables operation
## which is assumed ~O(1) in most cases (so long as the table does not degrade
## into one-bucket linear mode, or some adjustment algorithm.)
##

const
   # debugging, enable with: nim c -r -d:noisy:3 ...
   noisy {.intdefine.}: int = 0
   isMainOk {.used.} = noisy > 2

import
  math,
  stew/results,
  tables

export
  results

type
  LruKey*[T,K] =               ## derive an LRU key from function argument
    proc(arg: T): K {.gcsafe, raises: [Defect,CatchableError].}

  LruValue*[T,V,E] =           ## derive an LRU value from function argument
    proc(arg: T): Result[V,E] {.gcsafe, raises: [Defect,CatchableError].}

  LruItem[K,V] = tuple
    prv, nxt: K                ## doubly linked items
    value: V

  LruCache*[T,K,V,E] = object
    maxItems: int              ## max number of entries
    tab: Table[K,LruItem[K,V]] ## cache data table
    first, last: K             ## doubly linked item list queue
    toKey: LruKey[T,K]
    toValue: LruValue[T,V,E]

{.push raises: [Defect,CatchableError].}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc initLruCache*[T,K,V,E](cache: var LruCache[T,K,V,E];
                            toKey: LruKey[T,K], toValue: LruValue[T,V,E];
                            cacheMaxItems = 10) =
  ## Initialise new LRU cache
  cache.maxItems = cacheMaxItems
  cache.toKey = toKey
  cache.toValue = toValue
  cache.tab = initTable[K,LruItem[K,V]](cacheMaxItems.nextPowerOfTwo)


proc getLruItem*[T,K,V,E](cache: var LruCache[T,K,V,E]; arg: T): Result[V,E] =
  ## Return `toValue(arg)`, preferably from result cached earlier
  let key = cache.toKey(arg)

  # Relink item if already in the cache => move to last position
  if cache.tab.hasKey(key):
    let lruItem = cache.tab[key]

    if key == cache.last:
      # Nothing to do
      return ok(lruItem.value)

    # Unlink key Item
    if key == cache.first:
      cache.first = lruItem.nxt
    else:
      cache.tab[lruItem.prv].nxt = lruItem.nxt
      cache.tab[lruItem.nxt].prv = lruItem.prv

    # Append key item
    cache.tab[cache.last].nxt = key
    cache.tab[key].prv = cache.last
    cache.last = key
    return ok(lruItem.value)

  # Calculate value, pass through error unless OK
  let rcValue = ? cache.toValue(arg)

  # Limit number of cached items
  if cache.maxItems <= cache.tab.len:
    # Delete oldest/first entry
    var nextKey = cache.tab[cache.first].nxt
    cache.tab.del(cache.first)
    cache.first = nextKey

  # Add cache entry
  var tabItem: LruItem[K,V]

  # Initialise empty queue
  if cache.tab.len == 0:
    cache.first = key
    cache.last = key
  else:
    # Append queue item
    cache.tab[cache.last].nxt = key
    tabItem.prv = cache.last
    cache.last = key

  tabItem.value = rcValue
  cache.tab[key] = tabItem
  result = ok(rcValue)

# ------------------------------------------------------------------------------
# Debugging/testing
# ------------------------------------------------------------------------------

when isMainModule and isMainOK:

  import
    strformat

  const
    cacheLimit = 10
    keyList = [
      185, 208,  53,  54, 196, 189, 187, 117,  94,  29,   6, 173, 207,  45,  31,
      208, 127, 106, 117,  49,  40, 171,   6,  94,  84,  60, 125,  87, 168, 183,
      200, 155,  34,  27,  67, 107, 108, 223, 249,   4, 113,   9, 205, 100,  77,
      224,  19, 196,  14,  83, 145, 154,  95,  56, 236,  97, 115, 140, 134,  97,
      153, 167,  23,  17, 182, 116, 253,  32, 108, 148, 135, 169, 178, 124, 147,
      231, 236, 174, 211, 247,  22, 118, 144, 224,  68, 124, 200,  92,  63, 183,
      56,  107,  45, 180, 113, 233,  59, 246,  29, 212, 172, 161, 183, 207, 189,
      56,  198, 130,  62,  28,  53, 122]

  var
    getKey: LruKey[int,int] =
      proc(x: int): int = x

    getValue: LruValue[int,string,int] =
      proc(x: int): Result[string,int] = ok($x)

    cache: LruCache[int,int,string,int]

  cache.initLruCache(getKey, getValue, cacheLimit)

  proc verifyLinks[T,K,V,E](cache: var LruCache[T,K,V,E]) =
    var key = cache.first
    if cache.tab.len == 1:
      doAssert cache.tab.hasKey(key)
      doAssert key == cache.last
    elif 1 < cache.tab.len:
      # forward links
      for n in 1 ..< cache.tab.len:
        var curKey = key
        key = cache.tab[curKey].nxt
        if cache.tab[key].prv != curKey:
          echo &">>> ({n}): " &
            &"cache.tab[{key}].prv == {cache.tab[key].prv} exp {curKey}"
          doAssert cache.tab[key].prv == curKey
      doAssert key == cache.last
      # backward links
      for n in 1 ..< cache.tab.len:
        var curKey = key
        key = cache.tab[curKey].prv
        if cache.tab[key].nxt != curKey:
          echo &">>> ({n}): " &
            &"cache.tab[{key}].nxt == {cache.tab[key].nxt} exp {curKey}"
          doAssert cache.tab[key].nxt == curKey
      doAssert key == cache.first

  proc toKeyList[T,K,V,E](cache: var LruCache[T,K,V,E]): seq[K] =
    cache.verifyLinks
    if 0 < cache.tab.len:
      var key = cache.first
      while key != cache.last:
        result.add key
        key = cache.tab[key].nxt
      result.add cache.last

  proc toValueList[T,K,V,E](cache: var LruCache[T,K,V,E]): seq[V] =
    cache.verifyLinks
    if 0 < cache.tab.len:
      var key = cache.first
      while key != cache.last:
        result.add cache.tab[key].value
        key = cache.tab[key].nxt
      result.add cache.tab[cache.last].value

  var lastQ: seq[int]
  for w in keyList:
    var
      key = w mod 13
      reSched = cache.tab.hasKey(key)
      value = cache.getLruItem(key)
      queue = cache.toKeyList
      values = cache.toValueList
    # verfy key/value pairs
    for n in 0 ..< queue.len:
      doAssert $queue[n] == $values[n]
    if reSched:
      echo &"+++ rotate {value} => {queue}"
    else:
      echo &"*** append {value} => {queue}"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
