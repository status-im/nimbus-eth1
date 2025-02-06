# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
## The right way to use this file on a conditional mode is to import it as in
## ::
##   import ./path/to/core_db
##   when ..condition..
##     import ./path/to/core_db/persistent
##
{.push raises: [].}

import
  ../aristo,
  ./memory_only,
  ./backend/aristo_rocksdb,
  ../opts

export
  memory_only

proc newCoreDbRef*(
    dbType: static[CoreDbType];      # Database type symbol
    path: string;                    # Storage path for database
    opts: DbOptions;
      ): CoreDbRef =
  ## Constructor for persistent type DB
  ##
  ## The production database type is `AristoDbRocks` which uses a single
  ## `RocksDb` backend for both, `Aristo` and `KVT`.
  ##
  when dbType == AristoDbRocks:
    newAristoRocksDbCoreDbRef path, opts

  else:
    {.error: "Unsupported dbType for persistent newCoreDbRef()".}

# End
