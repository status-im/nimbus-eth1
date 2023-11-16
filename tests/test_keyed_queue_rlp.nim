# Nimbus
# Copyright (c) 2021-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[sequtils, strformat, strutils, tables],
  ../nimbus/utils/keyed_queue/kq_rlp,
  eth/rlp,
  stew/[keyed_queue, keyed_queue/kq_debug],
  unittest2

const
  usedStrutils = newSeq[string]().join(" ")

  lruCacheLimit = 10
  lruCacheModulo = 13

  keyList = [
    185, 208,  53,  54, 196, 189, 187, 117,  94,  29,   6, 173, 207,  45,  31,
    208, 127, 106, 117,  49,  40, 171,   6,  94,  84,  60, 125,  87, 168, 183,
    200, 155,  34,  27,  67, 107, 108, 223, 249,   4, 113,   9, 205, 100,  77,
    224,  19, 196,  14,  83, 145, 154,  95,  56, 236,  97, 115, 140, 134,  97,
    153, 167,  23,  17, 182, 116, 253,  32, 108, 148, 135, 169, 178, 124, 147,
    231, 236, 174, 211, 247,  22, 118, 144, 224,  68, 124, 200,  92,  63, 183,
    56,  107,  45, 180, 113, 233,  59, 246,  29, 212, 172, 161, 183, 207, 189,
    56,  198, 130,  62,  28,  53, 122]

type
  KUQueue = # mind the kqueue module from the nim standard lib
    KeyedQueue[uint,uint]

  LruCache = object
    size: int
    q: KUQueue

# ------------------------------------------------------------------------------
# Debugging
# ------------------------------------------------------------------------------

proc `$`(rc: KeyedQueuePair[uint,uint]): string =
  "(" & $rc.key & "," & $rc.data & ")"

proc `$`(rc: Result[KeyedQueuePair[uint,uint],void]): string =
  result = "<"
  if rc.isOK:
    result &= $rc.value.key & "," & $rc.value.data
  result &= ">"

proc `$`(rc: Result[uint,void]): string =
  result = "<"
  if rc.isOK:
    result &= $rc.value
  result &= ">"

proc say(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
  if noisy:
    if args.len == 0:
      echo "*** ", pfx
    elif 0 < pfx.len and pfx[^1] != ' ':
      echo pfx, " ", args.toSeq.join
    else:
      echo pfx, args.toSeq.join

# ------------------------------------------------------------------------------
# Converters
# ------------------------------------------------------------------------------

proc toValue(n: int): uint =
  (n + 1000).uint

proc fromValue(n: uint): int =
  (n - 1000).int

proc toKey(n: int): uint =
  n.uint

proc fromKey(n: uint): int =
  n.int

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc lruValue(lru: var LruCache; n: int): uint =
  let
    key = n.toKey
    rc = lru.q.lruFetch(key)
  if rc.isOK:
    return rc.value
  lru.q.lruAppend(key, key.fromKey.toValue, lru.size)

proc toLruCache(a: openArray[int]): LruCache =
  result.size = lruCacheLimit
  for n in a.toSeq.mapIt(it mod lruCacheModulo):
    doAssert result.lruValue(n) == n.toValue

proc toQueue(a: openArray[int]): KUQueue =
  for n in a:
    result[n.toKey] = n.toValue

proc toUnique(a: openArray[int]): seq[uint] =
  var q = a.toQueue
  toSeq(q.nextKeys)

proc addOrFlushGroupwise(rq: var KUQueue;
                         grpLen: int; seen: var seq[int]; n: int;
                         noisy = true) =
  seen.add n
  if seen.len < grpLen:
    return

  # flush group-wise
  let rqLen = rq.len
  noisy.say "updateSeen: deleting ", seen.mapIt($it).join(" ")
  for a in seen:
    doAssert rq.delete(a.toKey).value.data == a.toValue
  doAssert rqLen == seen.len + rq.len
  seen.setLen(0)

proc compileGenericFunctions(rq: var KUQueue) =
  ## Verifies that functions compile, at all
  rq.del(0)
  rq[0] = 0 # so `rq[0]` works
  discard rq[0]

  let ignoreValues = (
    (rq.append(0,0), rq.push(0,0),
     rq.replace(0,0),
     rq.prepend(0,0), rq.unshift(0,0),
     rq.shift, rq.shiftKey, rq.shiftValue,
     rq.pop, rq.popKey, rq.popValue,
     rq.delete(0)),

    (rq.hasKey(0), rq.eq(0)),

    (rq.firstKey, rq.secondKey, rq.beforeLastKey, rq.lastKey,
     rq.nextKey(0), rq.prevKey(0)),

    (rq.first, rq.second, rq.beforeLast, rq.last,
     rq.next(0), rq.prev(0)),

    (rq.firstValue, rq.secondValue, rq.beforeLastValue, rq.lastValue),

    (rq == rq, rq.len),

    (toSeq(rq.nextKeys), toSeq(rq.nextValues), toSeq(rq.nextPairs),
     toSeq(rq.prevKeys), toSeq(rq.prevValues), toSeq(rq.prevPairs)))

# ------------------------------------------------------------------------------
# Test Runners
# ------------------------------------------------------------------------------

proc runKeyedQueueRlp(noisy = true) =
  let
    uniqueKeys = keyList.toUnique
    numUniqeKeys = keyList.toSeq.mapIt((it,false)).toTable.len
    numKeyDups = keyList.len - numUniqeKeys

  suite "KeyedQueue: RLP stuff":

    test &"Simple rlp serialise + reload":
      var
        rp = [1, 2, 3].toQueue # keyList.toQueue
        rq = rp
      check rp == rq

      var
        sp = rlp.encode(rp)
        sq = rlp.encode(rq)
      check sp == sq

      var
        pr = sp.decode(type rp)
        qr = sq.decode(type rq)

      check pr.verify.isOK
      check qr.verify.isOK

      check pr == qr

    block:
      proc append(rw: var RlpWriter; lru: LruCache)
            {.inline, raises: [KeyError].} =
        rw.append((lru.size,lru.q))
      proc read(rlp: var Rlp; Q: type LruCache): Q
            {.inline, raises: [KeyError, RlpError].} =
        (result.size, result.q) = rlp.read((type result.size, type result.q))

      test "Rlp serialise & load, append":
          block:
            var
              c1 = keyList.toLruCache
              s1 = rlp.encode(c1)
              c2 = newSeq[int]().toLruCache

            noisy.say &"serialised[{s1.len}]: {s1}"
            c2.q.clear
            check c1 != c2
            check c1.q.verify.isOK
            check c2.q.verify.isOK

            c2 = s1.decode(type c2)
            check c1 == c2
            check c2.q.verify.isOK

            noisy.say &"c2Specs: {c2.size} {c2.q.firstKey} {c2.q.lastKey} ..."
            check s1 == rlp.encode(c2)

          block:
            var
              c1 = keyList.toLruCache
              value = c1.lruValue(77)
              queue = toSeq(c1.q.nextPairs).mapIt(it.key)
              values = toSeq(c1.q.nextPairs).mapIt(it.data)

            noisy.say &"c1: append {value} => {queue}"
            var
              s1 = rlp.encode(c1)
              c2 = keyList.toLruCache

            noisy.say &"serialised[{s1.len}]: {s1}"
            c2.q.clear
            check c1 != c2
            check c1.q.verify.isOK
            check c2.q.verify.isOK

            c2 = s1.decode(type c2)
            check c1 == c2
            noisy.say &"c2Specs: {c2.size} {c2.q.firstKey} {c2.q.lastKey} ..."
            check s1 == rlp.encode(c2)
            check c2.q.verify.isOK

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc keyedQueueRlpMain*(noisy = defined(debug)) =
  noisy.runKeyedQueueRlp

when isMainModule:
  let noisy = defined(debug)
  noisy.runKeyedQueueRlp

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
