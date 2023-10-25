# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## This module automatically pulls in the persistent backend libraries at the
## linking stage (e.g. `rocksdb`) which can be avoided for pure memory DB
## applications by importing `db/code_db/memory_only` (rather than
## `db/core_db/persistent`.)
##
{.push raises: [].}

import
  ../aristo,
  ./backend/[aristo_rocksdb, legacy_rocksdb],
  ./memory_only

export
  memory_only,
  toRocksStoreRef

proc newCoreDbRef*(
    dbType: static[CoreDbType];      # Database type symbol
    path: string;                    # Storage path for database
      ): CoreDbRef =
  ## Constructor for persistent type DB
  ##
  ## Note: Using legacy notation `newCoreDbRef()` rather than
  ## `CoreDbRef.init()` because of compiler coughing.
  when dbType == LegacyDbPersistent:
    newLegacyPersistentCoreDbRef path

  elif dbType == AristoDbRocks:
    newAristoRocksDbCoreDbRef path

  else:
    {.error: "Unsupported dbType for persistent newCoreDbRef()".}

proc newCoreDbRef*(
    dbType: static[CoreDbType];      # Database type symbol
    path: string;                    # Storage path for database
    qidLayout: QidLayoutRef;         # Optional for `Aristo`, ignored by others
      ): CoreDbRef =
  ## Constructor for persistent type DB
  ##
  ## Note: Using legacy notation `newCoreDbRef()` rather than
  ## `CoreDbRef.init()` because of compiler coughing.
  when dbType == AristoDbRocks:
    newAristoRocksDbCoreDbRef(path, qlr)

  else:
    {.error: "Unsupported dbType for persistent newCoreDbRef()" &
             " with qidLayout argument".}

# End
