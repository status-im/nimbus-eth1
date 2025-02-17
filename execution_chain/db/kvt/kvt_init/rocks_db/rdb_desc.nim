# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  ../../../core_db/backend/rocksdb_desc

export rocksdb_desc

type
  RdbInst* = object
    baseDb*: RocksDbInstanceRef

    store*: KvtCfStore               ## Rocks DB database handler

  KvtCFs* = enum
    ## Column family symbols/handles and names used on the database
    KvtGeneric = "KvtGen"            ## Generic column family

  KvtCfStore* = array[KvtCFs, ColFamilyReadWrite]
    ## List of column family handlers

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
