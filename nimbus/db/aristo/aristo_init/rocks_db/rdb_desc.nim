# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  std/[tables, os],
  eth/common,
  rocksdb/lib/librocksdb,
  rocksdb,
  stew/endians2,
  ../../aristo_desc,
  ../init_common

type
  RdbInst* = object
    dbOpts*: DbOptionsRef
    store*: RocksDbReadWriteRef      ## Rocks DB database handler
    basePath*: string                ## Database directory

    # Low level Rocks DB access for bulk store
    envOpt*: ptr rocksdb_envoptions_t
    impOpt*: ptr rocksdb_ingestexternalfileoptions_t

  RdbKey* = array[1 + sizeof VertexID, byte]
    ## Sub-table key, <pfx> + VertexID

  RdbTabs* = array[StorageType, Table[uint64,Blob]]
    ## Combined table for caching data to be stored/updated

const
  BaseFolder* = "nimbus"           # Same as for Legacy DB
  DataFolder* = "aristo"           # Legacy DB has "data"
  SstCache* = "bulkput"            # Rocks DB bulk load file name in temp folder
  TempFolder* = "tmp"              # No `tmp` directory used with legacy DB

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func baseDir*(rdb: RdbInst): string =
  rdb.basePath / BaseFolder

func dataDir*(rdb: RdbInst): string =
  rdb.baseDir / DataFolder

func cacheDir*(rdb: RdbInst): string =
  rdb.dataDir / TempFolder

func sstFilePath*(rdb: RdbInst): string =
  rdb.cacheDir / SstCache


func toRdbKey*(id: uint64; pfx: StorageType): RdbKey =
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
