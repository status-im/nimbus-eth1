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
  std/os,
  rocksdb/lib/librocksdb,
  rocksdb

type
  RdbInst* = object
    dbOpts*: DbOptionsRef
    store*: RocksDbReadWriteRef      ## Rocks DB database handler
    basePath*: string                ## Database directory

    # Low level Rocks DB access for bulk store
    envOpt*: ptr rocksdb_envoptions_t
    impOpt*: ptr rocksdb_ingestexternalfileoptions_t

const
  BaseFolder* = "nimbus"         # Same as for Legacy DB
  DataFolder* = "kvt"            # Legacy DB has "data"
  BackupFolder* = "kvt-history"  # Legacy DB has "backups"
  SstCache* = "bulkput"          # Rocks DB bulk load file name in temp folder
  TempFolder* = "tmp"            # No `tmp` directory used with legacy DB

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func baseDir*(rdb: RdbInst): string =
  rdb.basePath / BaseFolder

func dataDir*(rdb: RdbInst): string =
  rdb.baseDir / DataFolder

func backupsDir*(rdb: RdbInst): string =
  rdb.basePath / BaseFolder / BackupFolder

func cacheDir*(rdb: RdbInst): string =
  rdb.dataDir / TempFolder

func sstFilePath*(rdb: RdbInst): string =
  rdb.cacheDir / SstCache

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
