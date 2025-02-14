# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Rocksdb constructor/destructor for Kvt DB
## =========================================

{.push raises: [].}

import
  ./rdb_desc

export rdb_desc, results

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    rdb: var RdbInst;
    baseDb: RocksDbInstanceRef;
      ) =
  ## Database backend constructor for stand-alone version
  ##
  rdb.baseDb = baseDb

  for col in KvtCFs:
    # Failure here would indicate that the database was incorrectly opened which
    # shouldn't happen
    rdb.store[col] = baseDb.db.getColFamily($col).valueOr:
      raiseAssert "Cannot initialise " &
        $col & " descriptor: " & error

proc destroy*(rdb: var RdbInst; eradicate: bool) =
    rdb.baseDb.close(eradicate)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
