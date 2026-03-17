# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
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

iterator walkKey*(rdb: RdbInst): tuple[rvid: RootedVertexID, data: HashKey] =
  ## Walk over key-value pairs of the hash key column of the database.
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
    var value: HashKey
    var valid: bool

    proc readKey(data: openArray[byte]) =
      key = deblobify(data, RootedVertexID).valueOr:
        valid = false
        default(RootedVertexID)

    proc readValue(data: openArray[byte]) =
      value = deblobify(data, HashKey).valueOr:
        valid = false
        default(HashKey)

    while rit.isValid():
      valid = true
      rit.value(readValue)

      if valid:
        rit.key(readKey)
        if valid:
          yield (key, value)

      rit.next()

iterator walkVtx*(
    rdb: RdbInst, kinds: set[VertexType]): tuple[rvid: RootedVertexID, data: Vertex] =
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
    var value: Vertex
    var valid: bool

    proc readKey(data: openArray[byte]) =
      key = deblobify(data, RootedVertexID).valueOr:
        valid = false
        default(RootedVertexID)

    proc readValue(data: openArray[byte]) =
      let vType = deblobifyType(data, Vertex).valueOr:
        valid = false
        return

      if vType notin kinds:
        valid = false
        return

      value = deblobify(data, Vertex).valueOr:
        valid = false
        default(Vertex)

    while rit.isValid():
      valid = true
      rit.value(readValue)

      if valid:
        rit.key(readKey)
        if valid:
          yield (key, value)

      rit.next()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
