# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
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
    skeletonBlock
    skeletonTransaction
    snapSyncAccount
    snapSyncStorageSlot
    snapSyncStateRoot

  DbKey* = object
    # The first byte stores the key type. The rest are key-specific values
    data*: array[33, byte]
    dataEndPos*: uint8 # the last populated position in the data

proc genericHashKey*(h: Hash256): DbKey {.inline.} =
  result.data[0] = byte ord(genericHash)
  result.data[1 .. 32] = h.data
  result.dataEndPos = uint8 32

proc blockHashToScoreKey*(h: Hash256): DbKey {.inline.} =
  result.data[0] = byte ord(blockHashToScore)
  result.data[1 .. 32] = h.data
  result.dataEndPos = uint8 32

proc transactionHashToBlockKey*(h: Hash256): DbKey {.inline.} =
  result.data[0] = byte ord(transactionHashToBlock)
  result.data[1 .. 32] = h.data
  result.dataEndPos = uint8 32

proc blockNumberToHashKey*(u: BlockNumber): DbKey {.inline.} =
  result.data[0] = byte ord(blockNumberToHash)
  doAssert sizeof(u) <= 32
  copyMem(addr result.data[1], unsafeAddr u, sizeof(u))
  result.dataEndPos = uint8 sizeof(u)

proc canonicalHeadHashKey*(): DbKey {.inline.} =
  result.data[0] = byte ord(canonicalHeadHash)
  result.dataEndPos = 1

proc slotHashToSlotKey*(h: openArray[byte]): DbKey {.inline.} =
  doAssert(h.len == 32)
  result.data[0] = byte ord(slotHashToSlot)
  result.data[1 .. 32] = h
  result.dataEndPos = uint8 32

proc contractHashKey*(h: Hash256): DbKey {.inline.} =
  result.data[0] = byte ord(contractHash)
  result.data[1 .. 32] = h.data
  result.dataEndPos = uint8 32

proc cliqueSnapshotKey*(h: Hash256): DbKey {.inline.} =
  result.data[0] = byte ord(cliqueSnapshot)
  result.data[1 .. 32] = h.data
  result.dataEndPos = uint8 32

proc transitionStatusKey*(): DbKey =
  # ETH-2 Transition Status
  result.data[0] = byte ord(transitionStatus)
  result.dataEndPos = uint8 1

proc safeHashKey*(): DbKey {.inline.} =
  result.data[0] = byte ord(safeHash)
  result.dataEndPos = uint8 1

proc finalizedHashKey*(): DbKey {.inline.} =
  result.data[0] = byte ord(finalizedHash)
  result.dataEndPos = uint8 1

proc skeletonProgressKey*(): DbKey {.inline.} =
  result.data[0] = byte ord(skeletonProgress)
  result.dataEndPos = 1

proc skeletonBlockHashToNumberKey*(h: Hash256): DbKey {.inline.} =
  result.data[0] = byte ord(skeletonBlockHashToNumber)
  result.data[1 .. 32] = h.data
  result.dataEndPos = uint8 32

proc skeletonBlockKey*(u: BlockNumber): DbKey {.inline.} =
  result.data[0] = byte ord(skeletonBlock)
  doAssert sizeof(u) <= 32
  copyMem(addr result.data[1], unsafeAddr u, sizeof(u))
  result.dataEndPos = uint8 sizeof(u)

proc skeletonTransactionKey*(u: BlockNumber): DbKey {.inline.} =
  result.data[0] = byte ord(skeletonTransaction)
  doAssert sizeof(u) <= 32
  copyMem(addr result.data[1], unsafeAddr u, sizeof(u))
  result.dataEndPos = uint8 sizeof(u)

proc snapSyncAccountKey*(h: openArray[byte]): DbKey {.inline.} =
  doAssert(h.len == 32)
  result.data[0] = byte ord(snapSyncAccount)
  result.data[1 .. 32] = h
  result.dataEndPos = uint8 sizeof(h)

proc snapSyncStorageSlotKey*(h: openArray[byte]): DbKey {.inline.} =
  doAssert(h.len == 32)
  result.data[0] = byte ord(snapSyncStorageSlot)
  result.data[1 .. 32] = h
  result.dataEndPos = uint8 sizeof(h)

proc snapSyncStateRootKey*(h: openArray[byte]): DbKey {.inline.} =
  doAssert(h.len == 32)
  result.data[0] = byte ord(snapSyncStateRoot)
  result.data[1 .. 32] = h
  result.dataEndPos = uint8 sizeof(h)

template toOpenArray*(k: DbKey): openArray[byte] =
  k.data.toOpenArray(0, int(k.dataEndPos))

proc `==`*(a, b: DbKey): bool {.inline.} =
  a.toOpenArray == b.toOpenArray

