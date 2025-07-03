# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  eth/common/[base, hashes]

export base, hashes

type
  DBKeyKind* = enum
    # Careful - changing the assigned ordinals will break existing databases
    genericHash = 0
    blockNumberToHash = 1
    blockHashToScore = 2
    transactionHashToBlock = 3
    canonicalHeadHash = 4
    slotHashToSlot = 5
    contractHash = 6
    dataDirId = 7
    fcuNumAndHash = 8
    fcState = 9
    beaconHeader = 10
    wdKey = 11

  DbKey* = object
    # The first byte stores the key type. The rest are key-specific values
    data*: array[33, byte]
    dataEndPos*: uint8 # the last populated position in the data

  HashIndexKey* = array[34, byte]

func genericHashKey*(h: Hash32): DbKey {.inline.} =
  result.data[0] = byte ord(genericHash)
  result.data[1 .. 32] = h.data
  result.dataEndPos = uint8 32

func blockHashToScoreKey*(h: Hash32): DbKey {.inline.} =
  result.data[0] = byte ord(blockHashToScore)
  result.data[1 .. 32] = h.data
  result.dataEndPos = uint8 32

func transactionHashToBlockKey*(h: Hash32): DbKey {.inline.} =
  result.data[0] = byte ord(transactionHashToBlock)
  result.data[1 .. 32] = h.data
  result.dataEndPos = uint8 32

func blockNumberToHashKey*(u: BlockNumber): DbKey {.inline.} =
  result.data[0] = byte ord(blockNumberToHash)
  doAssert sizeof(u) <= 32
  copyMem(addr result.data[1], unsafeAddr u, sizeof(u))
  result.dataEndPos = uint8 sizeof(u)

func canonicalHeadHashKey*(): DbKey {.inline.} =
  result.data[0] = byte ord(canonicalHeadHash)
  result.dataEndPos = 1

func dataDirIdKey*(): DbKey {.inline.} =
  result.data[0] = byte ord(dataDirId)
  result.dataEndPos = 1

func slotHashToSlotKey*(h: Hash32): DbKey {.inline.} =
  result.data[0] = byte ord(slotHashToSlot)
  result.data[1 .. 32] = h.data()
  result.dataEndPos = uint8 32

func contractHashKey*(h: Hash32): DbKey {.inline.} =
  result.data[0] = byte ord(contractHash)
  result.data[1 .. 32] = h.data
  result.dataEndPos = uint8 32

template uint64KeyImpl(keyEnum) =
  result.data[0] = byte ord(keyEnum)
  doAssert sizeof(u) <= 32
  when nimvm:
    for i in 0..<sizeof(u):
      result.data[i+1] = byte((u shr (i * 8)) and 0xff)
  else:
    copyMem(addr result.data[1], unsafeAddr u, sizeof(u))
  result.dataEndPos = uint8 sizeof(u)

func fcuKey*(u: uint64): DbKey {.inline.} =
  uint64KeyImpl(fcuNumAndHash)

func hashIndexKey*(hash: Hash32, index: uint16): HashIndexKey =
  result[0..31] = hash.data
  result[32] = byte(index and 0xFF)
  result[33] = byte((index shl 8) and 0xFF)

func beaconHeaderKey*(u: BlockNumber): DbKey =
  uint64KeyImpl(beaconHeader)

func fcStateKey*(u: uint64): DbKey {.inline.} =
  uint64KeyImpl(fcState)

func withdrawalsKey*(h: Hash32): DbKey {.inline.} =
  result.data[0] = byte ord(wdKey)
  result.data[1 .. 32] = h.data
  result.dataEndPos = uint8 32

template toOpenArray*(k: DbKey): openArray[byte] =
  k.data.toOpenArray(0, int(k.dataEndPos))

func `==`*(a, b: DbKey): bool {.inline.} =
  a.toOpenArray == b.toOpenArray
