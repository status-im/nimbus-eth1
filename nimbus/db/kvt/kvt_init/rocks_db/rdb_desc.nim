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
  rocksdb

type
  RdbInst* = object
    store*: ColFamilyReadWrite       ## Rocks DB database handler
    session*: WriteBatchRef          ## For batched `put()`
    basePath*: string                ## Database directory

const
  KvtFamily* = "Kvt"                 ## RocksDB column family
  BaseFolder* = "nimbus"             ## Same as for Legacy DB
  DataFolder* = "kvt"                ## Legacy DB has "data"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func baseDir*(rdb: RdbInst): string =
  rdb.basePath / BaseFolder

func dataDir*(rdb: RdbInst): string =
  rdb.baseDir / DataFolder


template logTxt(info: static[string]): static[string] =
   "RocksDB/" & info

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
