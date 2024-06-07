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
  ../../aristo_desc,
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

proc getAdm*(rdb: RdbInst; xid: int): Result[Blob,(AristoError,string)] =
  var res: Blob
  let onData = proc(data: openArray[byte]) =
    res = @data

  let gotData = rdb.admCol.get(xid.uint64.toOpenArray, onData).valueOr:
     const errSym = RdbBeDriverGetAdmError
     when extraTraceMessages:
       trace logTxt "getAdm", xid, error=errSym, info=error
     return err((errSym,error))

  # Correct result if needed
  if not gotData:
    res = EmptyBlob
  ok move(res)

proc getKey*(rdb: var RdbInst; vid: uint64): Result[Blob,(AristoError,string)] =
  # Try LRU cache first
  var rc = rdb.rdKeyLru.lruFetch(vid)
  if rc.isOK:
    return ok(move(rc.value))

  # Otherwise fetch from backend database
  var res: Blob
  let onData = proc(data: openArray[byte]) =
    res = @data

  let gotData = rdb.keyCol.get(vid.toOpenArray, onData).valueOr:
     const errSym = RdbBeDriverGetKeyError
     when extraTraceMessages:
       trace logTxt "getKey", vid, error=errSym, info=error
     return err((errSym,error))

  # Correct result if needed
  if not gotData:
    res = EmptyBlob

  # Update cache and return
  ok rdb.rdKeyLru.lruAppend(vid, res, RdKeyLruMaxSize)


proc getVtx*(rdb: var RdbInst; vid: uint64): Result[Blob,(AristoError,string)] =
  # Try LRU cache first
  var rc = rdb.rdVtxLru.lruFetch(vid)
  if rc.isOK:
    return ok(move(rc.value))

  # Otherwise fetch from backend database
  var res: Blob
  let onData = proc(data: openArray[byte]) =
    res = @data

  let gotData = rdb.vtxCol.get(vid.toOpenArray, onData).valueOr:
    const errSym = RdbBeDriverGetVtxError
    when extraTraceMessages:
      trace logTxt "getVtx", vid, error=errSym, info=error
    return err((errSym,error))

  # Correct result if needed
  if not gotData:
    res = EmptyBlob

  # Update cache and return
  ok rdb.rdVtxLru.lruAppend(vid, res, RdVtxLruMaxSize)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
