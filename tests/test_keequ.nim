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
  std/[algorithm, sequtils, strformat, strutils, tables],
  ../nimbus/utils/keequ,
  eth/rlp,
  unittest2

const
  usedStrutils = newSeq[string]().join(" ")
  keyList = [
    185, 208,  53,  54, 196, 189, 187, 117,  94,  29,   6, 173, 207,  45,  31,
    208, 127, 106, 117,  49,  40, 171,   6,  94,  84,  60, 125,  87, 168, 183,
    200, 155,  34,  27,  67, 107, 108, 223, 249,   4, 113,   9, 205, 100,  77,
    224,  19, 196,  14,  83, 145, 154,  95,  56, 236,  97, 115, 140, 134,  97,
    153, 167,  23,  17, 182, 116, 253,  32, 108, 148, 135, 169, 178, 124, 147,
    231, 236, 174, 211, 247,  22, 118, 144, 224,  68, 124, 200,  92,  63, 183,
    56,  107,  45, 180, 113, 233,  59, 246,  29, 212, 172, 161, 183, 207, 189,
    56,  198, 130,  62,  28,  53, 122]

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc `$`(rc: KeeQuPair[uint,uint]): string =
  "(" & $rc.key & "," & $rc.data & ")"

proc `$`(rc: Result[KeeQuPair[uint,uint],void]): string =
  result = "<"
  if rc.isOK:
    result &= $rc.value.key & "," & $rc.value.data
  result &= ">"

proc `$`(rc: Result[uint,void]): string =
  result = "<"
  if rc.isOK:
    result &= $rc.value
  result &= ">"

proc toValue(n: int): uint =
  (n + 1000).uint

proc fromValue(n: uint): int =
  (n - 1000).int

proc toKey(n: int): uint =
  n.uint

proc fromKey(n: uint): int =
  n.int

proc toQueue(a: openArray[int]): KeeQu[uint,uint] =
  for n in a:
    result[n.toKey] = n.toValue

proc toUnique(a: openArray[int]): seq[uint] =
  var q = a.toQueue
  toSeq(q.nextKeys)

proc addOrFlushGroupwise(rq: var KeeQu[uint,uint];
                         grpLen: int; seen: var seq[int]; n: int;
                         noisy = true) =
  seen.add n
  if seen.len < grpLen:
    return

  # flush group-wise
  let rqLen = rq.len
  if noisy:
    echo "*** updateSeen: deleting ", seen.mapIt($it).join(" ")
  for a in seen:
    doAssert rq.delete(a.toKey).value.data == a.toValue
  doAssert rqLen == seen.len + rq.len
  seen.setLen(0)

proc compileGenericFunctions(rq: var KeeQu[uint,uint]) =
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

proc runKeeQu(noisy = true) =
  let
    uniqueKeys = keyList.toUnique
    numUniqeKeys = keyList.toSeq.mapIt((it,false)).toTable.len
    numKeyDups = keyList.len - numUniqeKeys

  suite "Data queue with keyed random access":
    block:
      var
        fwdRq, revRq: KeeQu[uint,uint]
        fwdRej, revRej: seq[int]

      test &"All functions smoke test":
        var rq: KeeQu[uint,uint]
        rq.compileGenericFunctions

      test &"Append/traverse {keyList.len} items, " &
          &"rejecting {numKeyDups} duplicates":
        var
          rq: KeeQu[uint,uint]
          rej: seq[int]
        for n in keyList:
          if not rq.push(n.toKey, n.toValue): # synonymous for append()
            rej.add n
          let check = rq.verify
          if check.isErr:
            check check.error[2] == keeQuOk
        check rq.len == numUniqeKeys
        check rej.len == numKeyDups
        check rq.len + rej.len == keyList.len
        fwdRq = rq
        fwdRej = rej

        check uniqueKeys == toSeq(rq.nextKeys)
        check uniqueKeys == toSeq(rq.prevKeys).reversed
        check uniqueKeys.len == numUniqeKeys

      test &"Prepend/traverse {keyList.len} items, " &
          &"rejecting {numKeyDups} duplicates":
        var
          rq: KeeQu[uint,uint]
          rej: seq[int]
        for n in keyList:
          if not rq.unshift(n.toKey, n.toValue): # synonymous for prepend()
            rej.add n
          let check = rq.verify
          if check.isErr:
            check check.error[2] == keeQuOk
        check rq.len == numUniqeKeys
        check rej.len == numKeyDups
        check rq.len + rej.len == keyList.len
        check toSeq(rq.nextKeys) == toSeq(rq.prevKeys).reversed
        revRq = rq
        revRej = rej

      test "Compare previous forward/reverse queues":
        check 0 < fwdRq.len
        check 0 < revRq.len
        check toSeq(fwdRq.nextKeys) == toSeq(revRq.prevKeys)
        check toSeq(fwdRq.prevKeys) == toSeq(revRq.nextKeys)
        check fwdRej.sorted == revRej.sorted

      test "Delete corresponding entries by keyed access from previous queues":
        var seen: seq[int]
        let sub7 = keyList.len div 7
        for n in toSeq(countUp(0,sub7)).concat(toSeq(countUp(3*sub7,4*sub7))):
          let
            key = keyList[n].toKey
            canDeleteOk = (key.fromKey notin seen)

            eqFwdData = fwdRq.eq(key)
            eqRevData = revRq.eq(key)

          if not canDeleteOk:
            check eqFwdData.isErr
            check eqRevData.isErr
          else:
            check eqFwdData.isOk
            check eqRevData.isOk
            let
              eqFwdEq = fwdRq.eq(eqFwdData.value.fromValue.toKey)
              eqRevEq = revRq.eq(eqRevData.value.fromValue.toKey)
            check eqFwdEq.isOk
            check eqRevEq.isOk
            let
              eqFwdKey = eqFwdEq.value.fromValue.toKey
              eqRevKey = eqRevEq.value.fromValue.toKey
            check eqFwdKey == key
            check eqRevKey == key

          let
            fwdData = fwdRq.delete(key)
            fwdRqCheck = fwdRq.verify
            revData = revRq.delete(key)
            revRqCheck = revRq.verify

          if key.fromKey notin seen:
            seen.add key.fromKey

          if fwdRqCheck.isErr:
            check fwdRqCheck.error[2] == keeQuOk
          check fwdData.isOk == canDeleteOk
          if revRqCheck.isErr:
            check revRqCheck.error[2] == keeQuOk
          check revData.isOk == canDeleteOk

          if canDeleteOk:
            check fwdData.value.data == revData.value.data
        check fwdRq.len == revRq.len
        check seen.len + fwdRq.len + fwdRej.len == keyList.len

    # --------------------------------------

    block:
      const groupLen = 7
      let veryNoisy = noisy and false

      test &"Load/forward/reverse iterate {numUniqeKeys} items, "&
          &"deleting in groups of at most {groupLen}":

        # forward ...
        block:
          var
            rq = keyList.toQueue
            seen: seq[int]
            all: seq[uint]
            rc = rq.first
          while rc.isOK:
            let key = rc.value.key
            all.add key
            rc = rq.next(key)
            rq.addOrFlushGroupwise(groupLen, seen, key.fromKey, veryNoisy)
            check rq.verify.isOK
          check seen.len == rq.len
          check seen.len < groupLen
          check uniqueKeys == all

        block:
          var
            rq = keyList.toQueue
            seen: seq[int]
            all: seq[uint]
          for w in rq.nextKeys:
            all.add w
            rq.addOrFlushGroupwise(groupLen, seen, w.fromKey, veryNoisy)
            check rq.verify.isOK
          check seen.len == rq.len
          check seen.len < groupLen
          check uniqueKeys == all
        block:
          var
            rq = keyList.toQueue
            seen: seq[int]
            all: seq[uint]
          for w in rq.nextPairs:
            all.add w.key
            rq.addOrFlushGroupwise(groupLen, seen, w.key.fromKey, veryNoisy)
            check rq.verify.isOK
          check seen.len == rq.len
          check seen.len < groupLen
          check uniqueKeys == all
        block:
          var
            rq = keyList.toQueue
            seen: seq[int]
            all: seq[uint]
          for v in rq.nextValues:
            let w = v.fromValue.toKey
            all.add w
            rq.addOrFlushGroupwise(groupLen, seen, w.fromKey, veryNoisy)
            check rq.verify.isOK
          check seen.len == rq.len
          check seen.len < groupLen
          check uniqueKeys == all

        # reverse ...
        block:
          var
            rq = keyList.toQueue
            seen: seq[int]
            all: seq[uint]
            rc = rq.last
          while rc.isOK:
            let key = rc.value.key
            all.add key
            rc = rq.prev(key)
            rq.addOrFlushGroupwise(groupLen, seen, key.fromKey, veryNoisy)
            check rq.verify.isOK
          check seen.len == rq.len
          check seen.len < groupLen
          check uniqueKeys == all.reversed

        block:
          var
            rq = keyList.toQueue
            seen: seq[int]
            all: seq[uint]
          for w in rq.prevKeys:
            all.add w
            rq.addOrFlushGroupwise(groupLen, seen, w.fromKey, veryNoisy)
            check rq.verify.isOK
          check seen.len == rq.len
          check seen.len < groupLen
          check uniqueKeys == all.reversed
        block:
          var
            rq = keyList.toQueue
            seen: seq[int]
            all: seq[uint]
          for w in rq.prevPairs:
            all.add w.key
            rq.addOrFlushGroupwise(groupLen, seen, w.key.fromKey, veryNoisy)
            check rq.verify.isOK
          check seen.len == rq.len
          check seen.len < groupLen
          check uniqueKeys == all.reversed
        block:
          var
            rq = keyList.toQueue
            seen: seq[int]
            all: seq[uint]
          for v in rq.prevValues:
            let w = v.fromValue.toKey
            all.add w
            rq.addOrFlushGroupwise(groupLen, seen, w.fromKey, veryNoisy)
            check rq.verify.isOK
          check seen.len == rq.len
          check seen.len < groupLen
          check uniqueKeys == all.reversed

      test &"Load/forward/reverse steps {numUniqeKeys} key/item consistency":

        # forward ...
        block:
          var
            rq = keyList.toQueue
            count = 0
            rc = rq.firstKey
          while rc.isOk:
            check uniqueKeys[count] == rc.value
            rc = rq.nextKey(rc.value)
            count.inc
          check rq.verify.isOK
          check count == uniqueKeys.len
        block:
          var
            rq = keyList.toQueue
            count = 0
            rc = rq.first
          while rc.isOk:
            check uniqueKeys[count] == rc.value.data.fromValue.toKey
            rc = rq.next(rc.value.key)
            count.inc
          check rq.verify.isOK
          check count == uniqueKeys.len

        # reverse ...
        block:
          var
            rq = keyList.toQueue
            count = uniqueKeys.len
            rc = rq.lastKey
          while rc.isOk:
            count.dec
            check uniqueKeys[count] == rc.value
            rc = rq.prevKey(rc.value)
          check rq.verify.isOK
          check count == 0
        block:
          var
            rq = keyList.toQueue
            count = uniqueKeys.len
            rc = rq.last
          while rc.isOk:
            count.dec
            check uniqueKeys[count] == rc.value.data.fromValue.toKey
            rc = rq.prev(rc.value.key)
          check rq.verify.isOK
          check count == 0

    # --------------------------------------

    test &"Load/delete second entries from either queue end "&
      "until only one left":
      block:
        var rq = keyList.toQueue
        while true:
          let rc = rq.secondKey
          if rc.isErr:
            check rq.second.isErr
            break
          let key = rc.value
          check rq.second.value.data == rq[key]
          check rq.delete(key).isOK
          check rq.verify.isOK
        check rq.len == 1
      block:
        var rq = keyList.toQueue
        while true:
          let rc = rq.beforeLastKey
          if rc.isErr:
            check rq.beforeLast.isErr
            break
          let key = rc.value
          check rq.beforeLast.value.data == rq[key]
          check rq.delete(key).isOK
          check rq.verify.isOK
        check rq.len == 1

    # --------------------------------------

    test &"Deep copy semantics":
      var
        rp = keyList.toQueue
        rq = rp
      let
        reduceLen = (rp.len div 3)
      check 0 < reduceLen
      check rp == rq
      for _ in 1 .. (rp.len div 3):
        let key = rp.firstKey.value
        check rp.delete(key).value.data.fromValue.toKey == key
      check rq.len == numUniqeKeys
      check rp.len + reduceLen == rq.len

    test &"Rlp serialise + reload":
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

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc keeQuMain*(noisy = defined(debug)) =
  noisy.runKeeQu

when isMainModule:
  let noisy = defined(debug)
  noisy.runKeeQu

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
