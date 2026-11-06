
# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  pkg/[results, rocksdb],
  pkg/stew/byteutils,
  ./[db_const, db_desc]

when extraTraceMessages:
  import chronicles

  logScope:
    topics = "snap sync"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc rGet*(adb: RocksDbRef, key: openArray[byte]): BlobResult =
  const info = "get: "

  var res: seq[byte]
  proc onData(data: openArray[byte]) =
    res = @data

  let rc = adb.get(key, onData)
  if rc.isErr:
    when extraTraceMessages:
      trace info & "key not found", key=key.toHex, `error`=rc.error
    return err(info & rc.error)

  if not rc.value:
    res = EmptyBlob
  ok(move res)

proc rPut*(
    adb: RocksDbReadWriteRef;
    key: openArray[byte];
    data: openArray[byte];
      ): PutResult =
  const info = "put: "
  adb.put(key, data).isOkOr:
    when extraTraceMessages:
      trace info & "failed", key=key.toHex, `error`=error
    return err(info & error)
  ok()

proc rDel*(adb: RocksDbReadWriteRef; key: openArray[byte]): DelResult =
  const info = "del: "
  adb.delete(key).isOkOr:
    when extraTraceMessages:
      trace info & "failed", key=key.toHex, `error`=error
    return err(info & error)
  ok()

proc rClear*(
    adb: RocksDbReadWriteRef;
    minKey: openArray[byte];
    maxKey: openArray[byte];
      ): DelResult =
  const info = "clear: "
  adb.deleteRange(minKey, maxKey).isOkOr:
    when extraTraceMessages:
      trace info & "failed", col=minKey[0], `error`=error
    return err(info & $error)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
