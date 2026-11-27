# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  chronicles,
  chronos/timer,
  results,
  rocksdb,
  stew/assign2,
  ./core_db,
  ./kvt/kvt_init/rocks_db,
  ./storage_types,
  ../evm/code_bytes

logScope:
  topics = "code-migration"

const
  legacyKind = byte ord(contractHash)
  codeKind = byte ord(contractCode)
  keyLen = 33
  batchLimit = 64 * 1024 * 1024
  progressInterval = seconds(10)

func isLegacyCode(key: openArray[byte]): bool =
  key.len > 0 and key[0] == legacyKind

proc migrateRecord(
    batch: WriteBatchRef, value: var seq[byte], key, code: openArray[byte]
): Result[int, string] =
  if key.len != keyLen or code.len == 0:
    return ok(0)

  let jumpdests = jumpdestBitmap(code)
  var codeKey: array[keyLen, byte]
  assign(codeKey, key)
  codeKey[0] = codeKind
  value.setLen(code.len + jumpdests.len)
  assign(value.toOpenArray(0, code.high), code)
  assign(value.toOpenArray(code.len, value.high), jumpdests)
  ?batch.put(codeKey, value)
  ?batch.delete(key)
  ok(value.len)

proc migrateLegacyCode*(db: CoreDbRef): Result[int, string] =
  let be = db.kvtBackend()
  if not (be of RdbBackendRef):
    return ok(0)

  let
    rdb = RdbBackendRef(be).getBaseDb().db
    cf = ?rdb.getColFamily($KvtGeneric)
    readOpts = defaultReadOptions(autoClose = true)
  readOpts.fillCache = false
  let
    iter = ?cf.openIterator(readOpts)
    batch = cf.openWriteBatch()
  defer:
    iter.close()
    batch.close()

  let start = Moment.now()
  var
    value: seq[byte]
    lastProgress = start
    pending, codes, bytes = 0

  iter.seekToKey([legacyKind])
  while iter.isValid() and isLegacyCode(iter.key(asOpenArray = true)):
    let written = ?batch.migrateRecord(
      value, iter.key(asOpenArray = true), iter.value(asOpenArray = true)
    )
    if written > 0:
      if codes == 0:
        info "Migrating contract code to the record format with jump destinations"
      codes += 1
      bytes += written
      pending += written
    if pending >= batchLimit:
      ?rdb.write(batch)
      batch.clear()
      pending = 0
      if Moment.now() - lastProgress >= progressInterval:
        lastProgress = Moment.now()
        info "Migrating contract code", codes, bytes
    iter.next()
  ?iter.status()

  if codes == 0:
    return ok(0)

  ?rdb.write(batch)
  ?cf.suggestCompactRange([legacyKind], [legacyKind + 1])
  info "Contract code migration completed",
    codes, bytes, elapsed = Moment.now() - start
  ok(codes)
