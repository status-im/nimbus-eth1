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
  rocksdb,
  results,
  ../../[aristo_blobify, aristo_desc],
  ./rdb_desc

const
  extraTraceMessages = false
    ## Enable additional logging noise

when extraTraceMessages:
  import chronicles

  logScope:
    topics = "aristo-rocksdb"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc begin*(rdb: var RdbInst): SharedWriteBatchRef =
  rdb.baseDb.openWriteBatch()

proc rollback*(rdb: var RdbInst, session: SharedWriteBatchRef) =
  if not session.isClosed():
    rdb.rdKeyLru = typeof(rdb.rdKeyLru).init(rdb.rdKeySize)
    rdb.rdVtxLru = typeof(rdb.rdVtxLru).init(rdb.rdVtxSize)
    rdb.rdBranchLru = typeof(rdb.rdBranchLru).init(rdb.rdBranchSize)
    session.close()

proc commit*(rdb: var RdbInst, session: SharedWriteBatchRef): Result[void,(AristoError,string)] =
  if not session.isClosed():
    defer: session.close()
    rdb.baseDb.commit(session, rdb.vtxCol).isOkOr:
      const errSym = RdbBeDriverWriteError
      when extraTraceMessages:
        trace logTxt "commit", error=errSym, info=error
      return err((errSym,error))
  ok()

proc putAdm*(
    rdb: var RdbInst; session: SharedWriteBatchRef,
    data: openArray[byte];
      ): Result[void,(AristoError,string)] =
  let dsc = session.batch
  if data.len == 0:
    dsc.delete(AdmKey, rdb.vtxCol.handle()).isOkOr:
      const errSym = RdbBeDriverDelAdmError
      when extraTraceMessages:
        trace logTxt "putAdm()", xid, error=errSym, info=error
      return err((errSym,error))
  else:
    dsc.put(AdmKey, data, rdb.vtxCol.handle()).isOkOr:
      const errSym = RdbBeDriverPutAdmError
      when extraTraceMessages:
        trace logTxt "putAdm()", xid, error=errSym, info=error
      return err((errSym,error))
  ok()

proc putVtx*(
    rdb: var RdbInst; session: SharedWriteBatchRef,
    rvid: RootedVertexID; vtx: VertexRef, key: HashKey
      ): Result[void,(VertexID,AristoError,string)] =
  let dsc = session.batch
  if vtx.isValid:
    dsc.put(rvid.blobify().data(), vtx.blobify(key), rdb.vtxCol.handle()).isOkOr:
      # Caller must `rollback()` which will flush the `rdVtxLru` cache
      const errSym = RdbBeDriverPutVtxError
      when extraTraceMessages:
        trace logTxt "putVtx()", vid, error=errSym, info=error
      return err((rvid.vid,errSym,error))

    # Update existing cached items but don't add new ones since doing so is
    # likely to evict more useful items (when putting many items, we might even
    # evict those that were just added)

    if vtx.vType == Branch:
      let vtx = BranchRef(vtx)
      rdb.rdVtxLru.del(rvid.vid)
      if rdb.rdBranchLru.len < rdb.rdBranchLru.capacity:
        rdb.rdBranchLru.put(rvid.vid, (vtx.startVid, vtx.used))
      else:
        discard rdb.rdBranchLru.update(rvid.vid, (vtx.startVid, vtx.used))
    else:
      rdb.rdBranchLru.del(rvid.vid)
      if rdb.rdVtxLru.len < rdb.rdVtxLru.capacity:
        rdb.rdVtxLru.put(rvid.vid, vtx)
      else:
        discard rdb.rdVtxLru.update(rvid.vid, vtx)

    rdb.rdEmptyLru.del(rvid.vid)

    if key.isValid:
      if rdb.rdKeyLru.len < rdb.rdKeyLru.capacity:
        rdb.rdKeyLru.put(rvid.vid, key)
      else:
        discard rdb.rdKeyLru.update(rvid.vid, key)
    else:
      rdb.rdKeyLru.del rvid.vid

  else:
    dsc.delete(rvid.blobify().data(), rdb.vtxCol.handle()).isOkOr:
      # Caller must `rollback()` which will flush the `rdVtxLru` cache
      const errSym = RdbBeDriverDelVtxError
      when extraTraceMessages:
        trace logTxt "putVtx()", vid, error=errSym, info=error
      return err((rvid.vid,errSym,error))

    # Update cache, vertex will most probably never be visited anymore
    rdb.rdBranchLru.del rvid.vid
    rdb.rdVtxLru.del rvid.vid
    rdb.rdKeyLru.del rvid.vid

    if rdb.rdEmptyLru.len < rdb.rdEmptyLru.capacity:
      rdb.rdEmptyLru.put(rvid.vid, default(tuple[]))

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
