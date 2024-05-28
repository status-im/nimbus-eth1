# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  eth/common

type
  DBKeyKind* = enum
    genericHash
    blockNumberToHash
    blockHashToScore
    transactionHashToBlock
    canonicalHeadHash
    slotHashToSlot
    contractHash
    cliqueSnapshot
    transitionStatus
    safeHash
    finalizedHash
    skeletonProgress
    skeletonBlockHashToNumber
    skeletonHeader
    skeletonBody
    snapSyncAccount
    snapSyncStorageSlot
    snapSyncStateRoot
    blockHashToBlockWitness

  DbKey* = object
    # The first byte stores the key type. The rest are key-specific values
    data*: array[33, byte]
    dataEndPos*: uint8 # the last populated position in the data

func genericHashKey*(h: Hash256): DbKey {.inline.} =
  result.data[0] = byte ord(genericHash)
  result.data[1 .. 32] = h.data
  result.dataEndPos = uint8 32

func blockHashToScoreKey*(h: Hash256): DbKey {.inline.} =
  result.data[0] = byte ord(blockHashToScore)
  result.data[1 .. 32] = h.data
  result.dataEndPos = uint8 32

func transactionHashToBlockKey*(h: Hash256): DbKey {.inline.} =
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

func slotHashToSlotKey*(h: openArray[byte]): DbKey {.inline.} =
  doAssert(h.len == 32)
  result.data[0] = byte ord(slotHashToSlot)
  result.data[1 .. 32] = h
  result.dataEndPos = uint8 32

func contractHashKey*(h: Hash256): DbKey {.inline.} =
  result.data[0] = byte ord(contractHash)
  result.data[1 .. 32] = h.data
  result.dataEndPos = uint8 32

func transitionStatusKey*(): DbKey =
  # ETH-2 Transition Status
  result.data[0] = byte ord(transitionStatus)
  result.dataEndPos = uint8 1

func safeHashKey*(): DbKey {.inline.} =
  result.data[0] = byte ord(safeHash)
  result.dataEndPos = uint8 1

func finalizedHashKey*(): DbKey {.inline.} =
  result.data[0] = byte ord(finalizedHash)
  result.dataEndPos = uint8 1

func skeletonProgressKey*(): DbKey {.inline.} =
  result.data[0] = byte ord(skeletonProgress)
  result.dataEndPos = 1

func skeletonBlockHashToNumberKey*(h: Hash256): DbKey {.inline.} =
  result.data[0] = byte ord(skeletonBlockHashToNumber)
  result.data[1 .. 32] = h.data
  result.dataEndPos = uint8 32

func skeletonHeaderKey*(u: BlockNumber): DbKey {.inline.} =
  result.data[0] = byte ord(skeletonHeader)
  doAssert sizeof(u) <= 32
  copyMem(addr result.data[1], unsafeAddr u, sizeof(u))
  result.dataEndPos = uint8 sizeof(u)

func skeletonBodyKey*(h: Hash256): DbKey {.inline.} =
  result.data[0] = byte ord(skeletonBody)
  result.data[1 .. 32] = h.data
  result.dataEndPos = uint8 32

func snapSyncAccountKey*(h: openArray[byte]): DbKey {.inline.} =
  doAssert(h.len == 32)
  result.data[0] = byte ord(snapSyncAccount)
  result.data[1 .. 32] = h
  result.dataEndPos = uint8 sizeof(h)

func snapSyncStorageSlotKey*(h: openArray[byte]): DbKey {.inline.} =
  doAssert(h.len == 32)
  result.data[0] = byte ord(snapSyncStorageSlot)
  result.data[1 .. 32] = h
  result.dataEndPos = uint8 sizeof(h)

func snapSyncStateRootKey*(h: openArray[byte]): DbKey {.inline.} =
  doAssert(h.len == 32)
  result.data[0] = byte ord(snapSyncStateRoot)
  result.data[1 .. 32] = h
  result.dataEndPos = uint8 sizeof(h)

func blockHashToBlockWitnessKey*(h: Hash256): DbKey {.inline.} =
  result.data[0] = byte ord(blockHashToBlockWitness)
  result.data[1 .. 32] = h.data
  result.dataEndPos = uint8 32

template toOpenArray*(k: DbKey): openArray[byte] =
  k.data.toOpenArray(0, int(k.dataEndPos))

func `==`*(a, b: DbKey): bool {.inline.} =
  a.toOpenArray == b.toOpenArray

