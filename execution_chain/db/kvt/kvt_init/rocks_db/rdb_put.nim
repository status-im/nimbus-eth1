# nimbus-eth1
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Rocks DB store data record
## ==========================

{.push raises: [].}

import
  results,
  ../../kvt_desc,
  ./rdb_desc

const
  extraTraceMessages = false
    ## Enable additional logging noise

when extraTraceMessages:
  import
    chronicles,
    stew/byteutils

  logScope:
    topics = "kvt-rocksdb"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

when extraTraceMessages:
  proc `$`(a: seq[byte]): string =
    a.toHex

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc put*(
    rdb: RdbInst;
    key, val: openArray[byte];
    cf: static[KvtCFs]): Result[void,(KvtError,string)] =
  rdb.store[cf].put(key, val).isOkOr:
    const errSym = RdbBeDriverPutError
    when extraTraceMessages:
      trace logTxt "put", key, error=errSym, info=error
    return err((errSym,error))
  ok()

proc write*(
    rdb: RdbInst;
    batch: KvtBatch;
    cf: static[KvtCFs]): Result[void,(KvtError,string)] =
  # A batch of its own: the shared one is written only when Aristo commits
  let wb = rdb.baseDb.db.openWriteBatch(rdb.store[cf].handle())
  defer: wb.close()
  for op in batch.ops:
    if op.val.isSome:
      wb.put(op.key, op.val.get()).isOkOr:
        const errSym = RdbBeDriverPutError
        when extraTraceMessages:
          trace logTxt "write", key=op.key, error=errSym, info=error
        return err((errSym,error))
    else:
      wb.delete(op.key).isOkOr:
        const errSym = RdbBeDriverDelError
        when extraTraceMessages:
          trace logTxt "write", key=op.key, error=errSym, info=error
        return err((errSym,error))
  rdb.baseDb.db.write(wb).isOkOr:
    const errSym = RdbBeDriverWriteError
    when extraTraceMessages:
      trace logTxt "write", error=errSym, info=error
    return err((errSym,error))
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
