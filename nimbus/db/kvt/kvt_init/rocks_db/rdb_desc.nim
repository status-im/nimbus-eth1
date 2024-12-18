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
  ../../kvt_desc,
  rocksdb

export rocksdb

type
  RdbInst* = object
    store*: KvtCfStore               ## Rocks DB database handler
    session*: WriteBatchRef          ## For batched `put()`

    basePath*: string                ## Database directory
    delayedPersist*: KvtDbRef        ## Enable next piggyback write session

  KvtCFs* = enum
    ## Column family symbols/handles and names used on the database
    KvtGeneric = "KvtGen"            ## Generic column family

  KvtCfStore* = array[KvtCFs, ColFamilyReadWrite]
    ## List of column family handlers

const
  BaseFolder* = "nimbus"             ## Same as for Legacy DB
  DataFolder* = "kvt"                ## Legacy DB has "data"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template logTxt*(info: static[string]): static[string] =
   "RocksDB/" & info


func baseDir*(rdb: RdbInst): string =
  rdb.basePath / BaseFolder

func dataDir*(rdb: RdbInst): string =
  rdb.baseDir / DataFolder


template baseDb*(rdb: RdbInst): RocksDbReadWriteRef =
  rdb.store[KvtGeneric].db

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
