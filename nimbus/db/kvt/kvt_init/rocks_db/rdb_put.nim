# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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

proc disposeSession(rdb: var RdbInst) =
  rdb.session.close()
  rdb.session = WriteBatchRef(nil)

when extraTraceMessages:
  proc `$`(a: seq[byte]): string =
    a.toHex

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc begin*(rdb: var RdbInst) =
  if rdb.session.isNil:
    rdb.session = rdb.baseDb.openWriteBatch()

proc rollback*(rdb: var RdbInst) =
  if not rdb.session.isClosed():
    rdb.disposeSession()

proc commit*(rdb: var RdbInst): Result[void,(KvtError,string)] =
  if not rdb.session.isClosed():
    defer: rdb.disposeSession()
    rdb.baseDb.write(rdb.session).isOkOr:
      const errSym = RdbBeDriverWriteError
      when extraTraceMessages:
        trace logTxt "commit", error=errSym, info=error
      return err((errSym,error))
  ok()

proc put*(
    rdb: RdbInst;
    key, val: openArray[byte];
      ): Result[void,(KvtError,string)] =
  if val.len == 0:
    rdb.session.delete(key, rdb.store[KvtGeneric].handle()).isOkOr:
      const errSym = RdbBeDriverDelError
      when extraTraceMessages:
        trace logTxt "del", key, error=errSym, info=error
      return err((errSym,error))
  else:
    rdb.session.put(key, val, rdb.store[KvtGeneric].handle()).isOkOr:
      const errSym = RdbBeDriverPutError
      when extraTraceMessages:
        trace logTxt "put", key, error=errSym, info=error
      return err((errSym,error))
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
