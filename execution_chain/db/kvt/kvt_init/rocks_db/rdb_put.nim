# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
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

proc begin*(rdb: var RdbInst): SharedWriteBatchRef =
  rdb.baseDb.openWriteBatch()

proc rollback*(rdb: var RdbInst, session: SharedWriteBatchRef) =
  if not session.isClosed():
    session.close()

proc commit*(
    rdb: var RdbInst, session: SharedWriteBatchRef, cf: static[KvtCFs]
): Result[void, (KvtError, string)] =
  if not session.isClosed():
    defer: session.close()
    rdb.baseDb.commit(session, rdb.store[cf], false).isOkOr:
      const errSym = RdbBeDriverWriteError
      when extraTraceMessages:
        trace logTxt "commit", error=errSym, info=error
      return err((errSym,error))
  ok()

proc put*(
    rdb: RdbInst;
    session: SharedWriteBatchRef,
    key, val: openArray[byte];
    cf: static[KvtCFs]): Result[void,(KvtError,string)] =
  if val.len == 0:
    session.batch.delete(key, rdb.store[cf].handle()).isOkOr:
      const errSym = RdbBeDriverDelError
      when extraTraceMessages:
        trace logTxt "del", key, error=errSym, info=error
      return err((errSym,error))
  else:
    session.batch.put(key, val, rdb.store[cf].handle()).isOkOr:
      const errSym = RdbBeDriverPutError
      when extraTraceMessages:
        trace logTxt "put", key, error=errSym, info=error
      return err((errSym,error))
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
