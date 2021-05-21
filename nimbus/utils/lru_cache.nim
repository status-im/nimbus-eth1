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
## provide last-recently-used cache mapper

const
   # debugging, enable with: nim c -r -d:noisy:3 ...
   noisy {.intdefine.}: int = 0
   isMainOk {.used.} = noisy > 2

import
  stew/results,
  tables

export
  results

type
  LruKey*[T,K] =               ## derive an LRU key from function argument
    proc(arg: T): K {.gcsafe, raises: [Defect,CatchableError].}

  LruValue*[T,V,E] =           ## derive an LRU value from function argument
    proc(arg: T): Result[V,E] {.gcsafe, raises: [Defect,CatchableError].}

  LruCache*[T,K,V,E] = object
    maxItems: int              ## max number of entries
    tab: OrderedTable[K,V]     ## cache data table
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
  # note: Starting from Nim v0.20, tables are initialized by default and it
  #       is not necessary to call initOrderedTable() function explicitly.


proc getLruItem*[T,K,V,E](cache: var LruCache[T,K,V,E]; arg: T): Result[V,E] =
  ## Return `toValue(arg)`, preferably from result cached earlier
  let key = cache.toKey(arg)

  # Get the cache if already generated, marking it as recently used
  if cache.tab.hasKey(key):
    let value = cache.tab[key]
    # Pop and append at end. Note that according to manual, this
    # costs O(n) => inefficient
    cache.tab.del(key)
    cache.tab[key] = value
    return ok(value)

  # Return unless OK
  let rcValue = ? cache.toValue(arg)

  # Limit mumer of cached items
  if cache.maxItems <= cache.tab.len:
    # Delete oldest/first entry
    var tbd: K
    # Kludge: OrderedTable[] still misses a proper API.
    for key in cache.tab.keys:
      # Tests suggest that deleting here also works in that particular case.
      tbd = key
      break
    cache.tab.del(tbd)

  # Add cache entry
  cache.tab[key] = rcValue
  result = ok(rcValue)

# ------------------------------------------------------------------------------
# Debugging/testing
# ------------------------------------------------------------------------------

when isMainModule and isMainOK:

  import
    sequtils

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

  var lastQ: seq[int]
  for w in keyList:
    var
      key = w mod 13
      reSched = cache.tab.hasKey(key)
      value = cache.getLruItem(key)
      queue = toSeq(cache.tab.keys)
    if reSched:
      echo "+++ rotate ", value, " => ", queue
    else:
      echo "*** append ", value, " => ", queue

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
