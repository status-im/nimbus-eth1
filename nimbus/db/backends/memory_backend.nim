# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import tables, hashes, eth_common

type
  DBKeyKind = enum
    genericHash
    blockNumberToHash
    blockHashToScore
    transactionHashToBlock
    canonicalHeadHash

  DbKey* = object
    case kind: DBKeyKind
    of genericHash, blockHashToScore, transactionHashToBlock:
      h: Hash256
    of blockNumberToHash:
      u: BlockNumber
    of canonicalHeadHash:
      discard

  MemoryDB* = ref object
    kvStore*: Table[DbKey, seq[byte]]

proc genericHashKey*(h: Hash256): DbKey {.inline.} = DbKey(kind: genericHash, h: h)
proc blockHashToScoreKey*(h: Hash256): DbKey {.inline.} = DbKey(kind: blockHashToScore, h: h)
proc transactionHashToBlockKey*(h: Hash256): DbKey {.inline.} = DbKey(kind: transactionHashToBlock, h: h)
proc blockNumberToHashKey*(u: BlockNumber): DbKey {.inline.} = DbKey(kind: blockNumberToHash, u: u)
proc canonicalHeadHashKey*(): DbKey {.inline.} = DbKey(kind: canonicalHeadHash)

proc hash(k: DbKey): Hash =
  result = result !& hash(k.kind)
  case k.kind
  of genericHash, blockHashToScore, transactionHashToBlock:
    result = result !& hash(k.h)
  of blockNumberToHash:
    result = result !& hashData(unsafeAddr k.u, sizeof(k.u))
  of canonicalHeadHash:
    discard
  result = result

proc `==`(a, b: DbKey): bool {.inline.} =
  equalMem(unsafeAddr a, unsafeAddr b, sizeof(a))

proc newMemoryDB*(kvStore: Table[DbKey, seq[byte]]): MemoryDB =
  MemoryDB(kvStore: kvStore)

proc newMemoryDB*: MemoryDB =
  MemoryDB(kvStore: initTable[DbKey, seq[byte]]())

proc get*(db: MemoryDB, key: DbKey): seq[byte] =
  db.kvStore[key]

proc set*(db: var MemoryDB, key: DbKey, value: seq[byte]) =
  db.kvStore[key] = value

proc contains*(db: MemoryDB, key: DbKey): bool =
  db.kvStore.hasKey(key)

proc delete*(db: var MemoryDB, key: DbKey) =
  db.kvStore.del(key)
