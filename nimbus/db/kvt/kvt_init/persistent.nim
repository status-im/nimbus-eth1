# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  results,
  ../../aristo,
  ../../opts,
  ../kvt_desc,
  "."/[rocks_db, memory_only]

export
  RdbBackendRef,
  memory_only

# ------------------------------------------------------------------------------
# Public database constuctors, destructor
# ------------------------------------------------------------------------------

proc init*(
    T: type KvtDbRef;
    B: type RdbBackendRef;
      ): Result[KvtDbRef,KvtError] =
  ## Generic constructor for `RocksDb` backend
  ##
  ok KvtDbRef(top: LayerRef.init(), backend: ? rocksDbKvtBackend basePath)

proc init*(
    T: type KvtDbRef;
    B: type RdbBackendRef;
    adb: AristoDbRef;
    opts: DbOptions;
      ): Result[KvtDbRef,KvtError] =
  ## Constructor for `RocksDb` backend which piggybacks on the `Aristo`
  ## backend.
  ok KvtDbRef(top: LayerRef.init(), backend: ? adb.rocksDbKvtBackend opts)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
