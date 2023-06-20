# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Rocks DB internal driver descriptor
## ===================================

{.push raises: [].}

import
  std/tables,
  eth/common,
  rocksdb,
  stint,
  ../../aristo_desc,
  ../aristo_init_common.nim

type
  RdbInst* = object
    store*: RocksDBInstance          ## Rocks DB database handler
    basePath*: string                ## Database directory

    # Low level Rocks DB access for bulk store
    envOpt*: rocksdb_envoptions_t
    impOpt*: rocksdb_ingestexternalfileoptions_t

  RdbKey* = array[1 + sizeof VertexID, byte]
    ## Sub-table key, <pfx> + VertexID

  RdbTabs* = array[AristoStorageType,Table[VertexID,Blob]]
    ## Combined table for caching data to be stored/updated

const
  BaseFolder* = "nimbus"         # Same as for Legacy DB has "backups"
  DataFolder* = "aristo"         # Legacy DB has "data"
  BackupFolder* = "history"      # Legacy DB has "backups"
  TempFolder* = "tmp"            # Not used with legacy DB
  SstCache* = "bulkput"          # Rocks DB bulk load file name in temp folder

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc toRdbKey*(vid: VertexID; pfx: AristoStorageType): Rdbkey =
  let vidKey = vid.uint64.toBytesBE
  result[0] = pfx.ord.byte
  copyMem(addr result[1], unsafeAddr vidKey, sizeof vidKey)

template toOpenArray*(vid: VertexID; pfx: AristoStorageType): openArray[byte] =
  vid.toRdbKey(pfx).toOpenArray(0, sizeof VertexID)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
