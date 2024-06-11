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
    vid: VertexID;
      ): Result[HashKey,(AristoError,string)] =
  # Try LRU cache first
  var rc = rdb.rdKeyLru.lruFetch(vid)
  if rc.isOK:
    return ok(move(rc.value))

  # Otherwise fetch from backend database
  var res: Result[HashKey,(AristoError,string)]
  let onData = proc(data: openArray[byte]) =
    res = HashKey.fromBytes(data).mapErr(proc(): auto =
      (RdbHashKeyExpected,""))

  let gotData = rdb.keyCol.get(vid.toOpenArray, onData).valueOr:
     const errSym = RdbBeDriverGetKeyError
     when extraTraceMessages:
       trace logTxt "getKey", vid, error=errSym, info=error
     return err((errSym,error))

  # Correct result if needed
  if not gotData:
    res = ok(VOID_HASH_KEY)
  elif res.isErr():
    return res # Parsing failed

  # Update cache and return
  ok rdb.rdKeyLru.lruAppend(vid, res.value(), RdKeyLruMaxSize)

proc getVtx*(
    rdb: var RdbInst;
    vid: VertexID;
      ): Result[VertexRef,(AristoError,string)] =
  # Try LRU cache first
  var rc = rdb.rdVtxLru.lruFetch(vid)
  if rc.isOK:
    return ok(move(rc.value))

  # Otherwise fetch from backend database
  var res: Result[VertexRef,(AristoError,string)]
  let onData = proc(data: openArray[byte]) =
    res = data.deblobify(VertexRef).mapErr(proc(error: AristoError): auto =
      (error,""))

  let gotData = rdb.vtxCol.get(vid.toOpenArray, onData).valueOr:
    const errSym = RdbBeDriverGetVtxError
    when extraTraceMessages:
      trace logTxt "getVtx", vid, error=errSym, info=error
    return err((errSym,error))

  if not gotData:
    res = ok(VertexRef(nil))
  elif res.isErr():
    return res # Parsing failed

  # Update cache and return
  ok rdb.rdVtxLru.lruAppend(vid, res.value(), RdVtxLruMaxSize)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
