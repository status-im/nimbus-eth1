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
  rocksdb

type
  RdbInst* = object
    store*: RocksDBInstance          ## Rocks DB database handler
    basePath*: string                ## Database directory

    # Low level Rocks DB access for bulk store
    envOpt*: rocksdb_envoptions_t
    impOpt*: rocksdb_ingestexternalfileoptions_t

const
  BaseFolder* = "nimbus"         # Same as for Legacy DB
  DataFolder* = "kvt"            # Legacy DB has "data"
  BackupFolder* = "khistory"     # Legacy DB has "backups"
  SstCache* = "kbulkput"         # Rocks DB bulk load file name in temp folder
  TempFolder* = "tmp"            # Not used with legacy DB (same for Aristo)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
