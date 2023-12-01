# Fluffy
# Copyright (c) 2021-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  unittest2, stint,
  eth/keys,
  ../network/state/state_content,
  ../database/content_db,
  ./test_helpers

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
    let usedSize = db.usedSize()

    check:
      size2 > size1
      size3 > size2
      size3 == size4
      usedSize == size4

    db.del(u256(2))
    db.del(u256(1))

    let usedSize1 = db.usedSize()
    let size5 = db.size()

    check:
      size4 == size5
      # The real size will be smaller as after a deletion there are free pages
      # in the db which can be re-used for further additions.
      usedSize1 < size5

    db.reclaimSpace()

    let size6 = db.size()
    let usedSize2 = db.usedSize()

    check:
      # After space reclamation the size of the db back to the initial size.
      size6 == size1
      usedSize2 == size6

  test "ContentDB pruning":
    # TODO: This test is extremely breakable when changing
    # `contentDeletionFraction` and/or the used test values.
    # Need to rework either this test, or the pruning mechanism, or probably
    # both.
    let
      storageCapacity = 100_000'u64
      db = ContentDB.new("", storageCapacity, inMemory = true)

      furthestElement = u256(40)
      secondFurthest = u256(30)
      thirdFurthest = u256(20)

      numBytes = 10_000
      pr1 = db.put(u256(1), genByteSeq(numBytes), u256(0))
      pr2 = db.put(thirdFurthest, genByteSeq(numBytes), u256(0))
      pr3 = db.put(u256(3), genByteSeq(numBytes), u256(0))
      pr4 = db.put(u256(10), genByteSeq(numBytes), u256(0))
      pr5 = db.put(u256(5), genByteSeq(numBytes), u256(0))
      pr6 = db.put(u256(11), genByteSeq(numBytes), u256(0))
      pr7 = db.put(furthestElement, genByteSeq(2000), u256(0))
      pr8 = db.put(secondFurthest, genByteSeq(2000), u256(0))
      pr9 = db.put(u256(2), genByteSeq(numBytes), u256(0))
      pr10 = db.put(u256(4), genByteSeq(12000), u256(0))

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
      pr10.deletedElements == 2
      uint64(db.usedSize()) < storageCapacity
      # With the current settings the 2 furthest elements will be deleted,
      # i.e key 30 and 40. The furthest non deleted one will have key 20.
      pr10.distanceOfFurthestElement == thirdFurthest
      db.get(furthestElement).isNone()
      db.get(secondFurthest).isNone()
      db.get(thirdFurthest).isSome()

  test "ContentDB force pruning":
    const
      # This start capacity doesn't really matter here as we are directly
      # putting data in the db without additional size checks.
      startCapacity = 14_159_872'u64
      endCapacity = 500_000'u64
      amountOfItems = 10_000

    let
      rng = newRng()
      db = ContentDB.new("", startCapacity, inMemory = true)
      localId = UInt256.fromHex(
        "30994892f3e4889d99deb5340050510d1842778acc7a7948adffa475fed51d6e")
      content = genByteSeq(1000)

    # Note: We could randomly generate the above localId and the content keys
    # that are added to the database below. However we opt for a more
    # deterministic test case as the randomness makes it difficult to chose a
    # reasonable value to check if pruning was succesful.
    let
      increment = UInt256.high div amountOfItems
      remainder = UInt256.high mod amountOfItems
    var id = u256(0)
    while id < UInt256.high - remainder:
      db.put(id, content)
      id = id + increment

    db.storageCapacity = endCapacity

    let
      oldRadiusApproximation = db.getLargestDistance(localId)
      newRadius = db.estimateNewRadius(oldRadiusApproximation)

    db.forcePrune(localId, newRadius)

    let diff = abs(db.size() - int64(db.storageCapacity))
    # Quite a big marging (20%) is added as it is all an approximation.
    check diff <  int64(float(db.storageCapacity) * 0.20)
