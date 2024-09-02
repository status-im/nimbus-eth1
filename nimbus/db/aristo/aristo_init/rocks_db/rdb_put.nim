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
  stew/keyed_queue,
  ../../[aristo_blobify, aristo_desc],
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

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc begin*(rdb: var RdbInst) =
  if rdb.session.isNil:
    rdb.session = rdb.baseDb.openWriteBatch()

proc rollback*(rdb: var RdbInst) =
  if not rdb.session.isClosed():
    rdb.rdKeyLru.clear() # Flush caches
    rdb.rdVtxLru.clear() # Flush caches
    rdb.disposeSession()

proc commit*(rdb: var RdbInst): Result[void,(AristoError,string)] =
  if not rdb.session.isClosed():
    defer: rdb.disposeSession()
    rdb.baseDb.write(rdb.session).isOkOr:
      const errSym = RdbBeDriverWriteError
      when extraTraceMessages:
        trace logTxt "commit", error=errSym, info=error
      return err((errSym,error))
  ok()


proc putAdm*(
    rdb: var RdbInst;
    xid: AdminTabID;
    data: openArray[byte];
      ): Result[void,(AdminTabID,AristoError,string)] =
  let dsc = rdb.session
  if data.len == 0:
    dsc.delete(xid.toOpenArray, rdb.admCol.handle()).isOkOr:
      const errSym = RdbBeDriverDelAdmError
      when extraTraceMessages:
        trace logTxt "putAdm()", xid, error=errSym, info=error
      return err((xid,errSym,error))
  else:
    dsc.put(xid.toOpenArray, data, rdb.admCol.handle()).isOkOr:
      const errSym = RdbBeDriverPutAdmError
      when extraTraceMessages:
        trace logTxt "putAdm()", xid, error=errSym, info=error
      return err((xid,errSym,error))
  ok()

proc putKey*(
    rdb: var RdbInst;
    rvid: RootedVertexID, key: HashKey;
      ): Result[void,(VertexID,AristoError,string)] =
  let dsc = rdb.session
  if key.isValid:
    dsc.put(rvid.blobify().data(), key.data, rdb.keyCol.handle()).isOkOr:
      # Caller must `rollback()` which will flush the `rdKeyLru` cache
      const errSym = RdbBeDriverPutKeyError
      when extraTraceMessages:
        trace logTxt "putKey()", vid, error=errSym, info=error
      return err((rvid.vid,errSym,error))

    # Update cache
    if not rdb.rdKeyLru.lruUpdate(rvid.vid, key):
      discard rdb.rdKeyLru.lruAppend(rvid.vid, key, RdKeyLruMaxSize)

  else:
    dsc.delete(rvid.blobify().data(), rdb.keyCol.handle()).isOkOr:
      # Caller must `rollback()` which will flush the `rdKeyLru` cache
      const errSym = RdbBeDriverDelKeyError
      when extraTraceMessages:
        trace logTxt "putKey()", vid, error=errSym, info=error
      return err((rvid.vid,errSym,error))

    # Update cache, vertex will most probably never be visited anymore
    rdb.rdKeyLru.del rvid.vid

  ok()


proc putVtx*(
    rdb: var RdbInst;
    rvid: RootedVertexID; vtx: VertexRef
      ): Result[void,(VertexID,AristoError,string)] =
  let dsc = rdb.session
  if vtx.isValid:
    dsc.put(rvid.blobify().data(), vtx.blobify(), rdb.vtxCol.handle()).isOkOr:
      # Caller must `rollback()` which will flush the `rdVtxLru` cache
      const errSym = RdbBeDriverPutVtxError
      when extraTraceMessages:
        trace logTxt "putVtx()", vid, error=errSym, info=error
      return err((rvid.vid,errSym,error))

    # Update cache
    if not rdb.rdVtxLru.lruUpdate(rvid.vid, vtx):
      discard rdb.rdVtxLru.lruAppend(rvid.vid, vtx, RdVtxLruMaxSize)

  else:
    dsc.delete(rvid.blobify().data(), rdb.vtxCol.handle()).isOkOr:
      # Caller must `rollback()` which will flush the `rdVtxLru` cache
      const errSym = RdbBeDriverDelVtxError
      when extraTraceMessages:
        trace logTxt "putVtx()", vid, error=errSym, info=error
      return err((rvid.vid,errSym,error))

    # Update cache, vertex will most probably never be visited anymore
    rdb.rdVtxLru.del rvid.vid

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
