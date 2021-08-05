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
  ../nimbus/utils/slst,
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

iterator fwdItems(sl: SLstRef[int,int]): int =
  var rc = sl.sLstGe(0)
  while rc.isOk:
    yield rc.value.key
    rc = sl.sLstGt(rc.value.key)

iterator revItems(sl: SLstRef[int,int]): int =
  var rc = sl.sLstLe(int.high)
  while rc.isOk:
    yield rc.value.key
    rc = sl.sLstLt(rc.value.key)

iterator fwdWalk(sl: SLstRef[int,int]): int =
  var
    w = sl.newSLstWalk
    rc = w.sLstFirst
  while rc.isOk:
    yield rc.value.key
    rc = w.sLstNext
  w.sLstWalkDestroy

iterator revWalk(sl: SLstRef[int,int]): int =
  var
    w = sl.newSLstWalk
  var
    rc = w.sLstLast
  while rc.isOk:
    yield rc.value.key
    rc = w.sLstPrev
  w.sLstWalkDestroy


proc runSLstTest(noisy = true) =
  let
    numUniqeKeys = keyList.toSeq.mapIt((it,false)).toTable.len
    numKeyDups = keyList.len - numUniqeKeys

  suite "Sorted list based on red-black tree":
    var
      sl = newSLst[int,int]()
      rej: seq[int]

    test &"Insert {keyList.len} items, reject {numKeyDups} duplicates":
      for n in keyList:
        let rc = sl.sLstInsert(n)
        if rc.isErr:
          rej.add n
        else:
          rc.value.value = -n
        let check = sl.sLstVerify
        if check.isErr:
          check check.error[1] == rbOk # force message
      check sl.len == numUniqeKeys
      check rej.len == numKeyDups
      check sl.len + rej.len == keyList.len

    test &"Verify increasing/decreasing traversals":
      check toSeq(sl.fwdItems) == toSeq(sl.fwdWalk)
      check toSeq(sl.revItems) == toSeq(sl.revWalk)
      check toSeq(sl.fwdItems) == toSeq(sl.revWalk).reversed
      check toSeq(sl.revItems) == toSeq(sl.fwdWalk).reversed

      # check `sLstEq()`
      block:
        var rc = sl.sLstGe(0)
        while rc.isOk:
          check rc == sl.sLstEq(rc.value.key)
          rc = sl.sLstGt(rc.value.key)

      # check `sLstThis()`
      block:
        var
          w = sl.newSLstWalk
          rc = w.sLstFirst
        while rc.isOk:
          check rc == w.sLstThis
          rc = w.sLstNext
        w.sLstWalkDestroy

    test "Delete items":
      var seen: seq[int]
      let sub7 = keyList.len div 7
      for n in toSeq(countUp(0,sub7)).concat(toSeq(countUp(3*sub7,4*sub7))):
        let
          key = keyList[n]
          canDeleteOk = (key notin seen)

          data = sl.sLstDelete(key)
          slCheck = sl.sLstVerify

        if key notin seen:
          seen.add key

        if slCheck.isErr:
          check slCheck.error[1] == rbOk # force message
        check data.isOk == canDeleteOk

        if canDeleteOk:
          check data.value.key == key

      check seen.len + sl.len + rej.len == keyList.len

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc sLstMain*(noisy = defined(debug)) =
  noisy.runSLstTest

when isMainModule:
  let noisy = true # defined(debug)
  noisy.runSLstTest

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
