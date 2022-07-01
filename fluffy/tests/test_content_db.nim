# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  std/algorithm,
  unittest2, stint,
  eth/keys,
  ../network/state/state_content,
  ../content_db,
  ./test_helpers

proc generateNRandomU256(rng: var HmacDrbgContext, n: int): seq[UInt256] =
  var i = 0
  var res = newSeq[Uint256]()
  while i < n:
    let bytes = rng.generateBytes(32)
    let num = Uint256.fromBytesBE(bytes)
    res.add(num)
    inc i
  return res

suite "Content Database":
  let rng = newRng()
  let testId = u256(0)
  # Note: We are currently not really testing something new here just basic
  # underlying kvstore.
  test "ContentDB basic API":
    let
      db = ContentDB.new("", uint32.high, inMemory = true)
      key = ContentId(UInt256.high()) # Some key

    block:
      let val = db.get(key)

      check:
        val.isNone()
        db.contains(key) == false

    block:
      discard db.put(key, [byte 0, 1, 2, 3], testId)
      let val = db.get(key)

      check:
        val.isSome()
        val.get() == [byte 0, 1, 2, 3]
        db.contains(key) == true

    block:
      db.del(key)
      let val = db.get(key)

      check:
        val.isNone()
        db.contains(key) == false

  test "ContentDB size":
    let
      db = ContentDB.new("", uint32.high, inMemory = true)

    let numBytes = 10000
    let size1 = db.size()
    discard db.put(u256(1), genByteSeq(numBytes), testId)
    let size2 = db.size()
    discard db.put(u256(2), genByteSeq(numBytes), testId)
    let size3 = db.size()
    discard db.put(u256(2), genByteSeq(numBytes), testId)
    let size4 = db.size()
    let realSize = db.realSize()

    check:
      size2 > size1
      size3 > size2
      size3 == size4
      realSize == size4

    db.del(u256(2))
    db.del(u256(1))
    
    let realSize1 = db.realSize()
    let size5 = db.size()
    
    check:
      size4 == size5
      # real size will be smaller as after del, there are free pages in sqlite
      # which can be re-used for further additions
      realSize1 < size5

    db.reclaimSpace()

    let size6 = db.size()
    let realSize2 = db.realSize()

    check:
      # After space reclamation size of db should be equal to initial size
      size6 == size1
      realSize2 == size6

  test "ContentDB pruning":
    let
      maxDbSize = uint32(100000)
      db = ContentDB.new("", maxDbSize, inMemory = true)

    let furthestElement = u256(40)
    let secondFurthest = u256(30)
    let thirdFurthest = u256(20)


    let numBytes = 10000
    let pr1 = db.put(u256(1), genByteSeq(numBytes), u256(0))
    let pr2 = db.put(thirdFurthest, genByteSeq(numBytes), u256(0))
    let pr3 = db.put(u256(3), genByteSeq(numBytes), u256(0))
    let pr4 = db.put(u256(10), genByteSeq(numBytes), u256(0))
    let pr5 = db.put(u256(5), genByteSeq(numBytes), u256(0))
    let pr6 = db.put(u256(10), genByteSeq(numBytes), u256(0))
    let pr7 = db.put(furthestElement, genByteSeq(numBytes), u256(0))
    let pr8 = db.put(secondFurthest, genByteSeq(numBytes), u256(0))
    let pr9 = db.put(u256(2), genByteSeq(numBytes), u256(0))
    let pr10 = db.put(u256(4), genByteSeq(numBytes), u256(0))

    check:
      pr1.kind == ContentStored
      pr2.kind == ContentStored
      pr3.kind == ContentStored
      pr4.kind == ContentStored
      pr5.kind == ContentStored
      pr6.kind == ContentStored
      pr7.kind == ContentStored
      pr8.kind == ContentStored
      pr9.kind == ContentStored
      pr10.kind == DbPruned

    check:
      pr10.numOfDeletedElements == 2
      uint32(db.realSize()) < maxDbSize
      # With current settings 2 furthers elements will be delted i.e 30 and 40
      # so the furthest non deleted one will be 20
      pr10.furthestStoredElementDistance == thirdFurthest
      db.get(furthestElement).isNone()
      db.get(secondFurthest).isNone()
      db.get(thirdFurthest).isSome()
