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

proc getImpl(rdb: RdbInst; key: RdbKey): Result[Blob,(AristoError,string)] =
  var res: Blob
  let onData = proc(data: openArray[byte]) =
    res = @data

  let gotData = rdb.store.get(key, onData).valueOr:
     const errSym = RdbBeDriverGetError
     when extraTraceMessages:
       trace logTxt "get", pfx=key[0], error=errSym, info=error
     return err((errSym,error))

  # Correct result if needed
  if not gotData:
    res = EmptyBlob
  ok res

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getByPfx*(
    rdb: RdbInst;
    pfx: StorageType;
    xid: uint64,
      ): Result[Blob,(AristoError,string)] =
  rdb.getImpl(xid.toRdbKey pfx)

proc getKey*(rdb: var RdbInst; xid: uint64): Result[Blob,(AristoError,string)] =
  # Try LRU cache first
  let
    key = xid.toRdbKey KeyPfx
    rc = rdb.rdKeyLru.lruFetch(key)
  if rc.isOK:
    return ok(rc.value)

  # Otherwise fetch from backend database
  let res = ? rdb.getImpl(key)

  # Update cache and return
  ok rdb.rdKeyLru.lruAppend(key, res, RdKeyLruMaxSize)

proc getVtx*(rdb: var RdbInst; xid: uint64): Result[Blob,(AristoError,string)] =
  # Try LRU cache first
  let
    key = xid.toRdbKey VtxPfx
    rc = rdb.rdVtxLru.lruFetch(key)
  if rc.isOK:
    return ok(rc.value)

  # Otherwise fetch from backend database
  let res = ? rdb.getImpl(key)

  # Update cache and return
  ok rdb.rdVtxLru.lruAppend(key, res, RdVtxLruMaxSize)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
