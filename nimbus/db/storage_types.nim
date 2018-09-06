import
  hashes, eth_common

type
  DBKeyKind* = enum
    genericHash
    blockNumberToHash
    blockHashToScore
    transactionHashToBlock
    canonicalHeadHash

  DbKey* = object
    # The first byte stores the key type. The rest are key-specific values
    data*: array[33, byte]
    dataEndPos*: uint8 # the last populated position in the data

  StorageError* = object of Exception

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
  assert sizeof(u) <= 32
  copyMem(addr result.data[1], unsafeAddr u, sizeof(u))
  result.dataEndPos = uint8 sizeof(u)

proc canonicalHeadHashKey*(): DbKey {.inline.} =
  result.data[0] = byte ord(canonicalHeadHash)
  result.dataEndPos = 1

const hashHolderKinds = {genericHash, blockHashToScore, transactionHashToBlock}

template toOpenArray*(k: DbKey): openarray[byte] =
  k.data.toOpenArray(0, int(k.dataEndPos))

proc hash*(k: DbKey): Hash =
  result = hash(k.toOpenArray)

# TODO: this should be added to Nim
proc `==`*[T](lhs, rhs: openarray[T]): bool =
  if lhs.len != rhs.len:
    return false

  for i in 0 ..< lhs.len:
    if lhs[i] != rhs[i]:
      return false

  return true

proc `==`*(a, b: DbKey): bool {.inline.} =
  a.toOpenArray == b.toOpenArray

template raiseStorageInitError* =
  raise newException(StorageError, "failure to initialize storage")

template raiseKeyReadError*(key: auto) =
  raise newException(StorageError, "failed to read key " & $key)

template raiseKeyWriteError*(key: auto) =
  raise newException(StorageError, "failed to write key " & $key)

template raiseKeySearchError*(key: auto) =
  raise newException(StorageError, "failure during search for key " & $key)

template raiseKeyDeletionError*(key: auto) =
  raise newException(StorageError, "failure to delete key " & $key)

