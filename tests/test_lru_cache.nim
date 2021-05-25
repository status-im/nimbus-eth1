# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ../nimbus/utils/lru_cache,
  eth/rlp,
  strformat,
  tables,
  unittest2

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

# Debugging output
proc say(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
  if noisy:
    var outText = pfx & " "
    for a in args.items:
      outText &= a
      echo outText


# Privy access to LRU internals
proc maxItems[T,K,V,E](cache: var LruCache[T,K,V,E]): int =
  cache.specs[0]

proc first[T,K,V,E](cache: var LruCache[T,K,V,E]): K =
  cache.specs[1]

proc last[T,K,V,E](cache: var LruCache[T,K,V,E]): K =
  cache.specs[2]

proc tab[T,K,V,E](cache: var LruCache[T,K,V,E]): TableRef[K,LruItem[K,V]] =
  cache.specs[3]


proc verifyLinks[T,K,V,E](lru: var LruCache[T,K,V,E]) =
  var key = lru.first
  if lru.tab.len == 1:
    doAssert lru.tab.hasKey(key)
    doAssert key == lru.last
  elif 1 < lru.tab.len:
    # forward links
    for n in 1 ..< lru.tab.len:
      var curKey = key
      key = lru.tab[curKey].nxt
      if lru.tab[key].prv != curKey:
        echo &"({n}): lru.tab[{key}].prv == {lru.tab[key].prv} exp {curKey}"
        doAssert lru.tab[key].prv == curKey
    doAssert key == lru.last
    # backward links
    for n in 1 ..< lru.tab.len:
      var curKey = key
      key = lru.tab[curKey].prv
      if lru.tab[key].nxt != curKey:
        echo &"({n}): lru.tab[{key}].nxt == {lru.tab[key].nxt} exp {curKey}"
        doAssert lru.tab[key].nxt == curKey
    doAssert key == lru.first

proc toKeyList[T,K,V,E](lru: var LruCache[T,K,V,E]): seq[K] =
    lru.verifyLinks
    if 0 < lru.tab.len:
      var key = lru.first
      while key != lru.last:
        result.add key
        key = lru.tab[key].nxt
      result.add lru.last

proc toValueList[T,K,V,E](lru: var LruCache[T,K,V,E]): seq[V] =
  lru.verifyLinks
  if 0 < lru.tab.len:
    var key = lru.first
    while key != lru.last:
      result.add lru.tab[key].value
      key = lru.tab[key].nxt
    result.add lru.tab[lru.last].value


proc createTestCache: LruCache[int,int,string,int] =
  var
    getKey: LruKey[int,int] =
      proc(x: int): int = x

    getValue: LruValue[int,string,int] =
      proc(x: int): Result[string,int] = ok($x)

    cache: LruCache[int,int,string,int]

  # Create LRU cache
  cache.initLruCache(getKey, getValue, cacheLimit)

  result = cache


proc filledTestCache(noisy: bool): LruCache[int,int,string,int] =
  var
    cache = createTestCache()
    lastQ: seq[int]

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
      noisy.say ">>>", &"rotate {value} => {queue}"
    else:
      noisy.say "+++", &"append {value} => {queue}"

  result = cache

# ---

proc doFillUpTest(noisy: bool) =
  discard filledTestCache(noisy)

proc doSerialiserTest(noisy: bool) =

  proc say(a: varargs[string]) =
    say(noisy = noisy, args = a)

  var
    c1 = filledTestCache(false)
    s1 = rlp.encode(c1.data)
    c2 = createTestCache()

  say &"serialised[{s1.len}]: {s1}"

  c2.clearLruCache
  doAssert c1 != c2

  c2.data = s1.decode(type c2.data)
  doAssert c1 == c2

  say &"c2Specs: {c2.maxItems} {c2.first} {c2.last} ..."

  doAssert s1 == rlp.encode(c2.data)

proc doSerialiseSingleEntry(noisy: bool) =

  proc say(a: varargs[string]) =
    say(noisy = noisy, args = a)

  var
    c1 = createTestCache()
    value = c1.getLruItem(77)
    queue = c1.toKeyList
    values = c1.toValueList

  say &"c1: append {value} => {queue}"

  var
    s1 = rlp.encode(c1.data)
    c2 = createTestCache()

  say &"serialised[{s1.len}]: {s1}"

  c2.clearLruCache
  doAssert c1 != c2

  c2.data = s1.decode(type c2.data)
  doAssert c1 == c2

  say &"c2Specs: {c2.maxItems} {c2.first} {c2.last} ..."

  doAssert s1 == rlp.encode(c2.data)


proc lruCacheMain*(noisy = defined(debug)) =
  suite "LRU Cache":

    test "Fill Up":
      doFillUpTest(noisy)

    test "Rlp Serialise & Load":
      doSerialiserTest(noisy)

    test "Rlp Single Entry Test":
      doSerialiseSingleEntry(noisy)


when isMainModule:
  lruCacheMain()

# End
