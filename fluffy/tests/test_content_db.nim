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
  ../content_db

proc genByteSeq(length: int): seq[byte] = 
  var i = 0
  var resultSeq = newSeq[byte](length)
  while i < length:
    resultSeq[i] = byte(i)
    inc i
  return resultSeq

proc generateNRandomU256(rng: var BrHmacDrbgContext, n: int): seq[UInt256] =
  var i = 0
  var res = newSeq[Uint256]()
  while i < n:
    var bytes = newSeq[byte](32)
    brHmacDrbgGenerate(rng, bytes)
    let num = Uint256.fromBytesBE(bytes)
    res.add(num)
    inc i
  return res

suite "Content Database":
  let rng = newRng()

  # Note: We are currently not really testing something new here just basic
  # underlying kvstore.
  test "ContentDB basic API":
    let
      db = ContentDB.new("", inMemory = true)
      key = ContentId(UInt256.high()) # Some key

    block:
      let val = db.get(key)

      check:
        val.isNone()
        db.contains(key) == false

    block:
      db.put(key, [byte 0, 1, 2, 3])
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
      db = ContentDB.new("", inMemory = true)

    let numBytes = 10000
    let size1 = db.size()
    db.put(@[1'u8], genByteSeq(numBytes))
    let size2 = db.size()
    db.put(@[2'u8], genByteSeq(numBytes))
    let size3 = db.size()
    db.put(@[2'u8], genByteSeq(numBytes))
    let size4 = db.size()

    check:
      size2 > size1
      size3 > size2
      size3 == size4

    db.del(@[2'u8])
    db.del(@[1'u8])
    
    let size5 = db.size()
    
    check:
      size4 == size5

    db.reclaimSpace()

    let size6 = db.size()

    check:
      # After space reclamation size of db should be equal to initial size
      size6 == size1

  type TestCase = object
    keys: seq[UInt256]
    n: uint64

  proc init(T: type TestCase, keys: seq[UInt256], n: uint64): T =
    TestCase(keys: keys, n: n)

  proc hasCorrectOrder(s: seq[ObjInfo], expectedOrder: seq[Uint256]): bool =
    var i = 0
    for e in s:
      if (e.distFrom != expectedOrder[i]):
        return false
      inc i
    return true
  
  test "Get N furthest elements from db":
    # we check distances from zero as num xor 0 = num, so each uint in sequence is valid
    # distance
    let zero = u256(0)
    let testCases = @[
      TestCase.init(@[], 10),
      TestCase.init(@[u256(1), u256(2)], 1),
      TestCase.init(@[u256(1), u256(2)], 2),
      TestCase.init(@[u256(5), u256(1), u256(2), u256(4)], 2),
      TestCase.init(@[u256(5), u256(1), u256(2), u256(4)], 4),
      TestCase.init(@[u256(57), u256(32), u256(108), u256(4)], 2),
      TestCase.init(@[u256(57), u256(32), u256(108), u256(4)], 4),
      TestCase.init(generateNRandomU256(rng[], 10), 5),
      TestCase.init(generateNRandomU256(rng[], 10), 10)
    ]

    for testCase in testCases:
      let
        db = ContentDB.new("", inMemory = true)

      for elem in testCase.keys:
        db.put(elem, genByteSeq(32))

      let furthest = db.getNFurthestElements(zero, testCase.n)

      var sortedKeys = testCase.keys

      sortedKeys.sort(SortOrder.Descending)

      if uint64(len(testCase.keys)) < testCase.n:
        check:
          len(furthest) == len(testCase.keys)
      else:
        check:
          uint64(len(furthest)) == testCase.n
      check:
        furthest.hasCorrectOrder(sortedKeys)
