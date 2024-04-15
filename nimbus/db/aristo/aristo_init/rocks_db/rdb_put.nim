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
  std/sequtils,
  eth/common,
  rocksdb/lib/librocksdb,
  rocksdb,
  results,
  ../../aristo_desc,
  ../init_common,
  ./rdb_desc

type
  RdbPutSession = object
    writer: ptr rocksdb_sstfilewriter_t
    sstPath: string
    nRecords: int

const
  extraTraceMessages = false
    ## Enable additional logging noise

when extraTraceMessages:
  import chronicles

  logScope:
    topics = "aristo-rocksdb"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc disposeSession(rdb: var RdbInst) =
  rdb.session.close()
  rdb.session = WriteBatchRef(nil)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc begin*(rdb: var RdbInst) =
  if rdb.session.isNil:
    rdb.session = rdb.store.openWriteBatch()

proc rollback*(rdb: var RdbInst) =
  if not rdb.session.isClosed():
    rdb.disposeSession()

proc commit*(rdb: var RdbInst): Result[void,(AristoError,string)] =
  if not rdb.session.isClosed():
    defer: rdb.disposeSession()
    rdb.store.write(rdb.session).isOkOr:
      const errSym = RdbBeDriverWriteError
      when extraTraceMessages:
        trace logTxt "commit", error=errSym, info=error
      return err((errSym,error))
  ok()

proc put*(
    rdb: RdbInst;
    pfx: StorageType;
    data: openArray[(uint64,Blob)];
      ): Result[void,(uint64,AristoError,string)] =
  let dsc = rdb.session # rdb.store
  assert not dsc.isNil
  for (xid,val) in data:
    let key = xid.toRdbKey pfx
    if val.len == 0:
      dsc.delete(key).isOkOr:
        const errSym = RdbBeDriverDelError
        when extraTraceMessages:
          trace logTxt "del", pfx, xid, error=errSym, info=error
        return err((xid,errSym,error))
    else:
      dsc.put(key, val).isOkOr:
        const errSym = RdbBeDriverPutError
        when extraTraceMessages:
          trace logTxt "put", pfx, xid, error=errSym, info=error
        return err((xid,errSym,error))
  ok()

proc put*(
    rdb: var RdbInst;
    tabs: RdbTabs;
      ): Result[void,(AristoError,string)] =
  rdb.begin()

  for (pfx,tab) in tabs.pairs:
    rdb.put(pfx, tab.pairs.toSeq).isOkOr:
      rdb.rollback()
      return err((error[1],error[2]))

  ? rdb.commit()
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
