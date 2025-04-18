# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Persistent constructor for Kvt DB
## ====================================
##
## This module automatically pulls in the persistent backend library at the
## linking stage (e.g. `rocksdb`) which can be avoided for pure memory DB
## applications by importing `./kvt_init/memory_only` (rather than
## `./kvt_init/persistent`.)
##
{.push raises: [].}

import
  ../kvt_desc,
  "."/[rocks_db, memory_only]

export
  memory_only,
  kvt_desc

# ------------------------------------------------------------------------------
# Public database constuctors, destructor
# ------------------------------------------------------------------------------

proc init*(
    T: type KvtDbRef;
    baseDb: RocksDbInstanceRef;
    cf: static[KvtCFs] = KvtGeneric): T =
  ## Generic constructor for `RocksDb` backend
  ##
  let db = rocksDbKvtBackend(baseDb, cf)
  db.txRef = KvtTxRef(db: db)
  db

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
