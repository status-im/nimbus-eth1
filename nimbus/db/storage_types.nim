import
  hashes, eth/common

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
    terminalHash
    safeHash
    finalizedHash
    snapSyncStatus
    snapSyncAccount
    snapSyncProof

  DbKey* = object
    # The first byte stores the key type. The rest are key-specific values
    data*: array[33, byte]
    dataEndPos*: uint8 # the last populated position in the data

  DbXKey* = object
    data*: array[65, byte]
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

proc terminalHashKey*(): DbKey =
  result.data[0] = byte ord(terminalHash)
  result.dataEndPos = uint8 1

proc safeHashKey*(): DbKey {.inline.} =
  result.data[0] = byte ord(safeHash)
  result.dataEndPos = uint8 1

proc finalizedHashKey*(): DbKey {.inline.} =
  result.data[0] = byte ord(finalizedHash)
  result.dataEndPos = uint8 1

proc snapSyncStatusKey*(h: Hash256): DbKey =
  result.data[0] = byte ord(snapSyncStatus)
  result.data[1 .. 32] = h.data
  result.dataEndPos = uint8 32

proc snapSyncAccountKey*(h, b: Hash256): DbXKey =
  result.data[0] = byte ord(snapSyncAccount)
  result.data[1 .. 32] = h.data
  result.data[33 .. 64] = b.data
  result.dataEndPos = uint8 64

proc snapSyncProofKey*(h: Hash256): DbKey =
  result.data[0] = byte ord(snapSyncProof)
  result.data[1 .. 32] = h.data
  result.dataEndPos = uint8 32

template toOpenArray*(k: DbKey|DbXKey): openArray[byte] =
  k.data.toOpenArray(0, int(k.dataEndPos))

proc hash*(k: DbKey|DbXKey): Hash =
  result = hash(k.toOpenArray)

proc `==`*(a, b: DbKey): bool {.inline.} =
  a.toOpenArray == b.toOpenArray

