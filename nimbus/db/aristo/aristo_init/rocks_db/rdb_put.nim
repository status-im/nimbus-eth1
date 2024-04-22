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
  eth/common,
  rocksdb,
  results,
  stew/[endians2, keyed_queue],
  ../../aristo_desc,
  ../init_common,
  ./rdb_desc

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

proc putImpl(
    dsc: WriteBatchRef;
    name: string;
    key: RdbKey;
    val: Blob;
      ): Result[void,(uint64,AristoError,string)] =
  if val.len == 0:
    dsc.delete(key, name).isOkOr:
      const errSym = RdbBeDriverDelError
      let xid = uint64.fromBytesBE key[1 .. 8]
      when extraTraceMessages:
        trace logTxt "del",
          pfx=StorageType(key[0]), xid, error=errSym, info=error
      return err((xid,errSym,error))
  else:
    dsc.put(key, val, name).isOkOr:
      const errSym = RdbBeDriverPutError
      let xid = uint64.fromBytesBE key[1 .. 8]
      when extraTraceMessages:
        trace logTxt "put",
          pfx=StorageType(key[0]), xid, error=errSym, info=error
      return err((xid,errSym,error))
  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc begin*(rdb: var RdbInst) =
  if rdb.session.isNil:
    rdb.session = rdb.store.openWriteBatch()

proc rollback*(rdb: var RdbInst) =
  if not rdb.session.isClosed():
    rdb.rdKeyLru.clear() # Flush caches
    rdb.rdVtxLru.clear() # Flush caches
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

proc putByPfx*(
    rdb: var RdbInst;
    pfx: StorageType;
    data: openArray[(uint64,Blob)];
      ): Result[void,(uint64,AristoError,string)] =
  let
    dsc = rdb.session
    name = rdb.store.name
  for (xid,val) in data:
    dsc.putImpl(name, xid.toRdbKey pfx, val).isOkOr:
      return err(error)
  ok()

proc putKey*(
    rdb: var RdbInst;
    data: openArray[(uint64,Blob)];
      ): Result[void,(uint64,AristoError,string)] =
  let
    dsc = rdb.session
    name = rdb.store.name
  for (xid,val) in data:
    let key = xid.toRdbKey KeyPfx

    # Update cache
    if not rdb.rdKeyLru.lruUpdate(key, val):
      discard rdb.rdKeyLru.lruAppend(key, val, RdKeyLruMaxSize)

    # Store on write batch queue
    dsc.putImpl(name, key, val).isOkOr:
      return err(error)
  ok()

proc putVtx*(
    rdb: var RdbInst;
    data: openArray[(uint64,Blob)];
      ): Result[void,(uint64,AristoError,string)] =
  let
    dsc = rdb.session
    name = rdb.store.name
  for (xid,val) in data:
    let key = xid.toRdbKey VtxPfx

    # Update cache
    if not rdb.rdVtxLru.lruUpdate(key, val):
      discard rdb.rdVtxLru.lruAppend(key, val, RdVtxLruMaxSize)

    # Store on write batch queue
    dsc.putImpl(name, key, val).isOkOr:
      return err(error)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
