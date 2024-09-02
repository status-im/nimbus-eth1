# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Rocks DB fetch data record
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
  import
    chronicles

  logScope:
    topics = "aristo-rocksdb"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getAdm*(rdb: RdbInst; xid: AdminTabID): Result[Blob,(AristoError,string)] =
  var res: Blob
  let onData = proc(data: openArray[byte]) =
    res = @data

  let gotData = rdb.admCol.get(xid.toOpenArray, onData).valueOr:
     const errSym = RdbBeDriverGetAdmError
     when extraTraceMessages:
       trace logTxt "getAdm", xid, error=errSym, info=error
     return err((errSym,error))

  # Correct result if needed
  if not gotData:
    res = EmptyBlob
  ok move(res)

proc getKey*(
    rdb: var RdbInst;
    rvid: RootedVertexID;
      ): Result[HashKey,(AristoError,string)] =
  # Try LRU cache first
  var rc = rdb.rdKeyLru.lruFetch(rvid.vid)
  if rc.isOK:
    return ok(move(rc.value))

  # Otherwise fetch from backend database
  # A threadvar is used to avoid allocating an environment for onData
  var res{.threadvar.}: Opt[HashKey]
  let onData = proc(data: openArray[byte]) =
    res = HashKey.fromBytes(data)

  let gotData = rdb.keyCol.get(rvid.blobify().data(), onData).valueOr:
     const errSym = RdbBeDriverGetKeyError
     when extraTraceMessages:
       trace logTxt "getKey", rvid, error=errSym, info=error
     return err((errSym,error))

  # Correct result if needed
  if not gotData:
    res.ok(VOID_HASH_KEY)
  elif res.isErr():
    return err((RdbHashKeyExpected,"")) # Parsing failed

  # Update cache and return
  ok rdb.rdKeyLru.lruAppend(rvid.vid, res.value(), RdKeyLruMaxSize)

proc getVtx*(
    rdb: var RdbInst;
    rvid: RootedVertexID;
      ): Result[VertexRef,(AristoError,string)] =
  # Try LRU cache first
  var rc = rdb.rdVtxLru.lruFetch(rvid.vid)
  if rc.isOK:
    return ok(move(rc.value))

  # Otherwise fetch from backend database
  # A threadvar is used to avoid allocating an environment for onData
  var res {.threadvar.}: Result[VertexRef,AristoError]
  let onData = proc(data: openArray[byte]) =
    res = data.deblobify(VertexRef)

  let gotData = rdb.vtxCol.get(rvid.blobify().data(), onData).valueOr:
    const errSym = RdbBeDriverGetVtxError
    when extraTraceMessages:
      trace logTxt "getVtx", vid, error=errSym, info=error
    return err((errSym,error))

  if not gotData:
    res.ok(VertexRef(nil))
  elif res.isErr():
    return err((res.error(), "Parsing failed")) # Parsing failed

  # Update cache and return
  ok rdb.rdVtxLru.lruAppend(rvid.vid, res.value(), RdVtxLruMaxSize)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
