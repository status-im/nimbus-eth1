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
  std/[algorithm, sequtils, strformat, tables],
  ../nimbus/utils/rnd_qu,
  unittest2

const
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

# ------------------------------------------------------------------------------
# Test Runners
# ------------------------------------------------------------------------------

proc runRndQu(noisy = true) =
  let
    numUniqeKeys = keyList.toSeq.mapIt((it,false)).toTable.len
    numKeyDups = keyList.len - numUniqeKeys

  suite "Data queue with keyed random access":
    var
      fwdRq, revRq: RndQuRef[int,int]
      fwdRej, revRej: seq[int]

    test &"Append and traverse {keyList.len} items, " &
        &"rejecting {numKeyDups} duplicates":
      var
        rq = newRndQu[int,int]()
        rej: seq[int]
      for n in keyList:
        let rc = rq.push(n) # synonymous for append()
        if rc.isErr:
          rej.add n
        else:
          rc.value.value = -n
        let check = rq.verify
        if check.isErr:
          check check.error[2] == rndQuOk
      check rq.len == numUniqeKeys
      check rej.len == numKeyDups
      check rq.len + rej.len == keyList.len
      check toSeq(rq.nextKeys) == toSeq(rq.prevKeys).reversed
      fwdRq = rq
      fwdRej = rej

    test &"Prepend and traverse {keyList.len} items, " &
        &"rejecting {numKeyDups} duplicates":
      var
        rq = newRndQu[int,int]()
        rej: seq[int]
      for n in keyList:
        let rc = rq.unshift(n) # synonymous for prepend()
        if rc.isErr:
          rej.add n
        else:
          rc.value.value = -n
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

    test "Delete corresponding random entries from previous queues":
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
          check fwdData.value.value == revData.value.value
      check fwdRq.len == revRq.len
      check seen.len + fwdRq.len + fwdRej.len == keyList.len

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc rndQuMain*(noisy = defined(debug)) =
  noisy.runRndQu

when isMainModule:
  let noisy = true # defined(debug)
  noisy.runRndQu

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
