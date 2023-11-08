# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
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
  stew/endians2,
  ../../aristo_desc,
  ../init_common

type
  RdbInst* = object
    store*: RocksDBInstance          ## Rocks DB database handler
    basePath*: string                ## Database directory

    # Low level Rocks DB access for bulk store
    envOpt*: rocksdb_envoptions_t
    impOpt*: rocksdb_ingestexternalfileoptions_t

  RdbKey* = array[1 + sizeof VertexID, byte]
    ## Sub-table key, <pfx> + VertexID

  RdbTabs* = array[StorageType,Table[uint64,Blob]]
    ## Combined table for caching data to be stored/updated

const
  BaseFolder* = "nimbus"         # Same as for Legacy DB
  DataFolder* = "aristo"         # Legacy DB has "data"
  BackupFolder* = "ahistory"     # Legacy DB has "backups"
  SstCache* = "abulkput"         # Rocks DB bulk load file name in temp folder
  TempFolder* = "tmp"            # Not used with legacy DB

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc toRdbKey*(id: uint64; pfx: StorageType): RdbKey =
  let idKey = id.toBytesBE
  result[0] = pfx.ord.byte
  copyMem(addr result[1], unsafeAddr idKey, sizeof idKey)

template toOpenArray*(vid: VertexID; pfx: StorageType): openArray[byte] =
  vid.uint64.toRdbKey(pfx).toOpenArray(0, sizeof uint64)

template toOpenArray*(qid: QueueID): openArray[byte] =
  qid.uint64.toRdbKey(FilPfx).toOpenArray(0, sizeof uint64)

template toOpenArray*(aid: AdminTabID): openArray[byte] =
  aid.uint64.toRdbKey(AdmPfx).toOpenArray(0, sizeof uint64)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
