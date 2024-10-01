# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Rocks DB store data iterator
## ============================
##
{.push raises: [].}

import
  eth/common,
  stew/endians2,
  rocksdb,
  ./rdb_desc,
  ../../aristo_blobify,
  ../../aristo_desc/desc_identifiers

const
  extraTraceMessages = false
    ## Enable additional logging noise

when extraTraceMessages:
  import
    chronicles

  logScope:
    topics = "aristo-rocksdb"

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator walkAdm*(rdb: RdbInst): tuple[xid: uint64, data: seq[byte]] =
  ## Walk over key-value pairs of the admin column of the database.
  ##
  ## Non-decodable entries are are ignored.
  ##
  block walkBody:
    let rit = rdb.admCol.openIterator().valueOr:
      when extraTraceMessages:
        trace logTxt "walkAdm()", error
      break walkBody
    defer: rit.close()

    for (key,val) in rit.pairs:
      if key.len == 8 and val.len != 0:
        yield (uint64.fromBytesBE key, val)

iterator walkKey*(rdb: RdbInst): tuple[rvid: RootedVertexID, data: seq[byte]] =
  ## Walk over key-value pairs of the hash key column of the database.
  ##
  ## Non-decodable entries are are ignored.
  ##
  block walkBody:
    let rit = rdb.keyCol.openIterator().valueOr:
      when extraTraceMessages:
        trace logTxt "walkKey()", error
      break walkBody
    defer: rit.close()

    for (key,val) in rit.pairs:
      if val.len != 0:
        let rvid = key.deblobify(RootedVertexID).valueOr:
          continue

        yield (rvid, val)


iterator walkVtx*(rdb: RdbInst): tuple[rvid: RootedVertexID, data: VertexRef] =
  ## Walk over key-value pairs of the vertex column of the database.
  ##
  ## Non-decodable entries are are ignored.
  ##
  block walkBody:
    let rit = rdb.vtxCol.openIterator().valueOr:
      when extraTraceMessages:
        trace logTxt "walkVtx()", error
      break walkBody
    defer: rit.close()

    rit.seekToFirst()
    var key: RootedVertexID
    var value: VertexRef
    while rit.isValid():
      var valid = true
      rit.key(
        proc(data: openArray[byte]) =
          key = deblobify(data, RootedVertexID).valueOr:
            valid = false
            default(RootedVertexID)
      )
      if not valid:
        continue

      rit.value(
        proc(data: openArray[byte]) =
          value = deblobify(data, VertexRef).valueOr:
            valid = false
            default(VertexRef)
      )
      if not valid:
        continue

      rit.next()
      yield (key, value)
    rit.close()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
