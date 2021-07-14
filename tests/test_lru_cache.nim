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
  sequtils,
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


proc verifyBackLinks[T,K,V,E](lru: var LruCache[T,K,V,E]) =
  var
    index = 0
    prvKey: K
  for key,item in lru.keyItemPairs:
    if 0 < index:
      doAssert prvKey == item.prv
    index.inc
    prvKey = key

proc toKeyList[T,K,V,E](lru: var LruCache[T,K,V,E]): seq[K] =
  lru.verifyBackLinks
  toSeq(lru.keyItemPairs).mapIt(it[0])

proc toValueList[T,K,V,E](lru: var LruCache[T,K,V,E]): seq[V] =
  lru.verifyBackLinks
  toSeq(lru.keyItemPairs).mapIt(it[1].value)

proc createTestCache: LruCache[int,int,string,int] =
  var
    getKey: LruKey[int,int] =
      proc(x: int): int = x

    getValue: LruValue[int,string,int] =
      proc(x: int): Result[string,int] = ok($x)

    cache: LruCache[int,int,string,int]

  # Create LRU cache
  cache.initCache(getKey, getValue, cacheLimit)

  result = cache


proc filledTestCache(noisy: bool): LruCache[int,int,string,int] =
  var
    cache = createTestCache()
    lastQ: seq[int]

  for w in keyList:
    var
      key = w mod 13
      reSched = cache.hasKey(key)
      value = cache.getItem(key)
      queue = cache.toKeyList
      values = cache.toValueList
    if reSched:
      noisy.say ">>>", &"rotate {value} => {queue}"
    else:
      noisy.say "+++", &"append {value} => {queue}"
    doAssert queue.mapIt($it) == values
    doAssert key == cache.lastKey

  result = cache

# ---

proc doFillUpTest(noisy: bool) =
  discard filledTestCache(noisy)


proc doDeepCopyTest(noisy: bool) =

  proc say(a: varargs[string]) =
    say(noisy = noisy, args = a)

  var
    c1 = filledTestCache(false)
    c2 = c1

  doAssert c1 == c2
  discard c1.getItem(77)

  say &"c1Specs: {c1.maxLen} {c1.firstKey} {c1.lastKey} ..."
  say &"c2Specs: {c2.maxLen} {c2.firstKey} {c2.lastKey} ..."

  doAssert c1 != c2
  doAssert toSeq(c1.keyItemPairs) != toSeq(c2.keyItemPairs)


proc doSerialiserTest(noisy: bool) =

  proc say(a: varargs[string]) =
    say(noisy = noisy, args = a)

  var
    c1 = filledTestCache(false)
    s1 = rlp.encode(c1.data)
    c2 = createTestCache()

  say &"serialised[{s1.len}]: {s1}"

  c2.clearCache
  doAssert c1 != c2

  c2.data = s1.decode(type c2.data)
  doAssert c1 == c2

  say &"c2Specs: {c2.maxLen} {c2.firstKey} {c2.lastKey} ..."

  doAssert s1 == rlp.encode(c2.data)


proc doSerialiseSingleEntry(noisy: bool) =

  proc say(a: varargs[string]) =
    say(noisy = noisy, args = a)

  var
    c1 = createTestCache()
    value = c1.getItem(77)
    queue = c1.toKeyList
    values = c1.toValueList

  say &"c1: append {value} => {queue}"

  var
    s1 = rlp.encode(c1.data)
    c2 = createTestCache()

  say &"serialised[{s1.len}]: {s1}"

  c2.clearCache
  doAssert c1 != c2

  c2.data = s1.decode(type c2.data)
  doAssert c1 == c2

  say &"c2Specs: {c2.maxLen} {c2.firstKey} {c2.lastKey} ..."

  doAssert s1 == rlp.encode(c2.data)


proc doRandomDeleteTest(noisy: bool) =

  proc say(a: varargs[string]) =
    say(noisy = noisy, args = a)

  var
    c1 = filledTestCache(false)
    sq = toSeq(c1.keyItemPairs).mapIt(it[0])
    s0 = sq
    inx = 5
    key = sq[5]

  sq.delete(5,5)
  say &"sq: {s0} <off sq[5]({key})> {sq}"

  doAssert c1.delItem(key)
  doAssert sq == toSeq(c1.keyItemPairs).mapIt(it[0])
  c1.verifyBackLinks


proc lruCacheMain*(noisy = defined(debug)) =
  suite "LRU Cache":

    test "Fill Up":
      doFillUpTest(noisy)

    test "Deep Copy Semantics":
      doDeepCopyTest(noisy)

    test "Rlp Serialise & Load":
      doSerialiserTest(noisy)

    test "Rlp Single Entry Test":
      doSerialiseSingleEntry(noisy)

    test "Random Delete":
      doRandomDeleteTest(noisy)


when isMainModule:
  lruCacheMain()

# End
