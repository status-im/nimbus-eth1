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
  ../nimbus/utils/rnd_qu,
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

proc `$`(item: RndQuItemRef[int,int]): string =
  "<" & $item.prv & "<" & $item.data & ">" & $item.nxt & ">"

proc `$`(rc: RndQuResult[int,int]): string =
  if rc.isErr:
    return "<>"
  $rc.value

proc toQueue(a: openArray[int]): RndQuRef[int,int] =
  result = newRndQu[int,int]()
  for n in a:
    result[n] = -n

proc addOrFlushGroupwise(rq: RndQuRef[int,int];
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
    doAssert rq.delete(a).value.data == -a
  doAssert rqLen == seen.len + rq.len
  seen.setLen(0)

# ------------------------------------------------------------------------------
# Test Runners
# ------------------------------------------------------------------------------

proc runRndQu(noisy = true) =
  let
    uniqueKeys = toSeq(keyList.toQueue.nextKeys)
    numUniqeKeys = keyList.toSeq.mapIt((it,false)).toTable.len
    numKeyDups = keyList.len - numUniqeKeys

  suite "Data queue with keyed random access":
    block:
      var
        fwdRq, revRq: RndQuRef[int,int]
        fwdRej, revRej: seq[int]

      test &"Append/traverse {keyList.len} items, " &
          &"rejecting {numKeyDups} duplicates":
        var
          rq = newRndQu[int,int]()
          rej: seq[int]
        for n in keyList:
          let rc = rq.push(n) # synonymous for append()
          if rc.isErr:
            rej.add n
          else:
            rc.value.data = -n
          let check = rq.verify
          if check.isErr:
            check check.error[2] == rndQuOk
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
          rq = newRndQu[int,int]()
          rej: seq[int]
        for n in keyList:
          let rc = rq.unshift(n) # synonymous for prepend()
          if rc.isErr:
            rej.add n
          else:
            rc.value.data = -n
          let check = rq.verify
          if check.isErr:
            check check.error[2] == rndQuOk
        check rq.len == numUniqeKeys
        check rej.len == numKeyDups
        check rq.len + rej.len == keyList.len
        check toSeq(rq.nextKeys) == toSeq(rq.prevKeys).reversed
        revRq = rq
        revRej = rej

      test "Compare previous forward/reverse queues":
        if fwdRq == nil or revRq == nil:
          skip()
        else:
          check toSeq(fwdRq.nextKeys) == toSeq(revRq.prevKeys)
          check toSeq(fwdRq.prevKeys) == toSeq(revRq.nextKeys)
          check fwdRej.sorted == revRej.sorted

      test "Delete corresponding entries by keyed access from previous queues":
        var seen: seq[int]
        let sub7 = keyList.len div 7
        for n in toSeq(countUp(0,sub7)).concat(toSeq(countUp(3*sub7,4*sub7))):
          let
            key = keyList[n]
            canDeleteOk = (key notin seen)

            eqFwdData = fwdRq.eq(key)
            eqRevData = revRq.eq(key)

          if not canDeleteOk:
            check eqFwdData.isErr
            check eqRevData.isErr
          else:
            check eqFwdData.isOk
            check eqRevData.isOk
            let
              eqFwdKey = fwdRq.eq(eqFwdData.value)
              eqRevKey = revRq.eq(eqRevData.value)
            check eqFwdKey.isOk
            check eqFwdKey.value == key
            check eqRevKey.isOk
            check eqRevKey.value == key

          let
            fwdData = fwdRq.delete(key)
            fwdRqCheck = fwdRq.verify
            revData = revRq.delete(key)
            revRqCheck = revRq.verify

          if key notin seen:
            seen.add key

          if fwdRqCheck.isErr:
            check fwdRqCheck.error[2] == rndQuOk
          check fwdData.isOk == canDeleteOk
          if revRqCheck.isErr:
            check revRqCheck.error[2] == rndQuOk
          check revData.isOk == canDeleteOk

          if canDeleteOk:
            check fwdData.value.data == revData.value.data
        check fwdRq.len == revRq.len
        check seen.len + fwdRq.len + fwdRej.len == keyList.len

    # --------------------------------------

    block:
      const groupLen = 7
      let veryNoisy = noisy and false

      test &"Load/forward iterate {numUniqeKeys} items, "&
          &"deleting in groups of at most {groupLen}":
        block:
          var
            rq = keyList.toQueue
            seen, all: seq[int]
          for w in rq.nextKeys:
            all.add w
            rq.addOrFlushGroupwise(groupLen, seen, w, veryNoisy)
            check rq.verify.isOK
          check seen.len == rq.len
          check seen.len < groupLen
          check uniqueKeys == all
        block:
          var
            rq = keyList.toQueue
            seen, all: seq[int]
          for w,_ in rq.nextPairs:
            all.add w
            rq.addOrFlushGroupwise(groupLen, seen, w, veryNoisy)
            check rq.verify.isOK
          check seen.len == rq.len
          check seen.len < groupLen
          check uniqueKeys == all
        block:
          var
            rq = keyList.toQueue
            seen, all: seq[int]
          for v in rq.nextValues:
            all.add -v
            rq.addOrFlushGroupwise(groupLen, seen, -v, veryNoisy)
            check rq.verify.isOK
          check seen.len == rq.len
          check seen.len < groupLen
          check uniqueKeys == all

      test &"Load/reverse iterate {numUniqeKeys} items, "&
          &"deleting in groups of at most {groupLen}":
        block:
          var
            rq = keyList.toQueue
            seen, all: seq[int]
          for w in rq.prevKeys:
            all.add w
            rq.addOrFlushGroupwise(groupLen, seen, w, veryNoisy)
            check rq.verify.isOK
          check seen.len == rq.len
          check seen.len < groupLen
          check uniqueKeys == all.reversed
        block:
          var
            rq = keyList.toQueue
            seen, all: seq[int]
          for w,_ in rq.prevPairs:
            all.add w
            rq.addOrFlushGroupwise(groupLen, seen, w, veryNoisy)
            check rq.verify.isOK
          check seen.len == rq.len
          check seen.len < groupLen
          check uniqueKeys == all.reversed
        block:
          var
            rq = keyList.toQueue
            seen, all: seq[int]
          for v in rq.prevValues:
            all.add -v
            rq.addOrFlushGroupwise(groupLen, seen, -v, veryNoisy)
            check rq.verify.isOK
          check seen.len == rq.len
          check seen.len < groupLen
          check uniqueKeys == all.reversed

      test &"Load/forward steps {numUniqeKeys} key/item consistency":
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
            check uniqueKeys[count] == -rc.value.data
            rc = rq.next(rc.value)
            count.inc
          check rq.verify.isOK
          check count == uniqueKeys.len

      test &"Load/reverse steps {numUniqeKeys} key/item consistency":
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
            check uniqueKeys[count] == -rc.value.data
            rc = rq.prev(rc.value)
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

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc rndQuMain*(noisy = defined(debug)) =
  noisy.runRndQu

when isMainModule:
  let noisy = defined(debug)
  noisy.runRndQu

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
