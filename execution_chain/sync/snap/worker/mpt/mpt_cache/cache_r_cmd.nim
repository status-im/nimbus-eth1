
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
  std/typetraits,
  pkg/[results, rocksdb],
  pkg/stew/byteutils,
  ../mpt_desc,
  ./[cache_const, cache_desc]

when extraTraceMessages:
  import chronicles

  logScope:
    topics = "snap sync"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc rGet*(adb: RocksDbRef, key: openArray[byte]): BlobResult =
  const info = "mpt/get: "

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
  const info = "mpt/put: "
  adb.put(key, data).isOkOr:
    when extraTraceMessages:
      trace info & "failed", key=key.toHex, `error`=error
    return err(info & error)
  ok()

proc rDel*(adb: RocksDbReadWriteRef; key: openArray[byte]): DelResult =
  const info = "mpt/del: "
  adb.delete(key).isOkOr:
    when extraTraceMessages:
      trace info & "failed", key=key.toHex, `error`=error
    return err(info & error)
  ok()

proc rClear*(
    adb: RocksDbReadWriteRef;
    col: MptAsmCol;
    force = false;
      ): DelResult =
  const info = "mpt/clear: "
  let rit = adb.openIterator().valueOr:
    return err(info & "Iterator open error, col=" & $col & ", error=" & $error)
  defer: rit.close()

  var
    nErrors = 0
    key: seq[byte]

  rit.seekToKey(@[col.ord.byte])
  while rit.isValid():
    key.setLen(0)
    rit.key(proc(w: openArray[byte]) {.gcsafe, raises: [].} = key = @w)
    rit.next()

    if 0 < key.len:
      if col.ord.byte != key[0]:
        break

      adb.delete(key).isOkOr:
        if not force:
          return err(info & "Deletion failed" &
            ", col=" & $col & ", error=" & $error)
        nErrors.inc

  if 0 < nErrors:
    err(info & "Some deletions failed" &
      ", col=" & $col & ", nFailed=" & $nErrors)
  else:
    ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
