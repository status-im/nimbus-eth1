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
  "../.."/[kvt_constants, kvt_desc],
  ./rdb_desc

const
  extraTraceMessages = false
    ## Enable additional logging noise

when extraTraceMessages:
  import
    chronicles

  logScope:
    topics = "kvt-rocksdb"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc get*(
    rdb: RdbInst;
    key: openArray[byte],
      ): Result[seq[byte],(KvtError,string)] =
  var res: seq[byte]
  let onData: DataProc = proc(data: openArray[byte]) =
    res = @data

  let gotData = rdb.store[KvtGeneric].get(key, onData).valueOr:
    const errSym = RdbBeDriverGetError
    when extraTraceMessages:
      trace logTxt "get", error=errSym, info=error
    return err((errSym,error))

  if not gotData:
    res = EmptyBlob
  ok move(res)

proc len*(
    rdb: RdbInst;
    key: openArray[byte],
      ): Result[int,(KvtError,string)] =
  var res: int
  let onData: DataProc = proc(data: openArray[byte]) =
    res = data.len

  let gotData = rdb.store[KvtGeneric].get(key, onData).valueOr:
    const errSym = RdbBeDriverGetError
    when extraTraceMessages:
      trace logTxt "len", error=errSym, info=error
    return err((errSym,error))

  if not gotData:
    res = 0
  ok res

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
