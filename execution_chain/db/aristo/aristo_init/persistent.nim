# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Persistent constructor for Aristo DB
## ====================================
##
## This module automatically pulls in the persistent backend library at the
## linking stage (e.g. `rocksdb`) which can be avoided for pure memory DB
## applications by importing `./aristo_init/memory_only` (rather than
## `./aristo_init/persistent`.)
##
{.push raises: [].}

import
  results,
  rocksdb,
  ../../opts,
  ../aristo_desc,
  ./rocks_db/rdb_desc,
  "."/[init_common, rocks_db]

export
  AristoDbRef,
  RdbBackendRef,
  RdbWriteEventCb,
  init_common,
  aristo_desc

# ------------------------------------------------------------------------------
# Public database constuctors, destructor
# ------------------------------------------------------------------------------

proc init*(
    T: type AristoDbRef;
    B: type RdbBackendRef;
    opts: DbOptions;
    baseDb: RocksDbInstanceRef;
      ): Result[T, AristoError] =
  let
    be = rocksDbBackend(opts, baseDb)
    db = AristoDbRef.init(be).valueOr:
      be.closeFn(eradicate = false)
      return err(error)
  ok db

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
