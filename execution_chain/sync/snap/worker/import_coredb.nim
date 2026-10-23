# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Not for production, yet.
## ------------------------
##
## Module depends on CoreDb/Aristo. This module allows to build a second
## CoreDb/Aristo database parallel to the existing one.
##
{.push raises: [].}

import
  pkg/chronicles,
  ./import_coredb/[coredb_desc, coredb_import],
  ./[helpers, cache_db, worker_desc]

export
  coredb_desc

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc importCoreDb*(
    db: CoreDbRef;
    tx: CoreDbTxRef;
    adb: CacheDbRef;
    info: static[string];
    stopOnError = false;
      ): Opt[CoredbImportStats] =
  ## Import the flat tables into a version of CoreDb.
  ##
  let
    status = ?adb.getAccMissingIntv(info)
    header = ?adb.getHeader(status.number, info)
    txStats = db.importFlat(tx, adb, stopOnError, info) # import data

  if 0 < txStats.nErrors:
    error info & ": Error importing snap data", number=status.number, txStats
    return err()

  let txStateRoot = ?tx.fetchStateRoot(info)
  if header.stateRoot != txStateRoot:
    error info & ": Dtate roots differ when importing snap data",
      number=status.number, stateRoot=header.stateRoot.toStr,
      expected=txStateRoot.toStr, txStats
    return err()

  ok(txStats)

proc importCoreDb*(
    ctx: SnapCtxRef;
    info: static[string];
    stopOnError = true;
      ): Opt[CoredbImportStats] =
  ## Import the flat tables into a temporary CoreDb version. After assembly,
  ## the temporary database is closed and wiped.
  ##
  ## This function is for debugging, only.
  ##
  let
    adb = ctx.pool.cacheDB
    db2 = CoreDb2Ref.init(ctx)
  defer: db2.destroy()

  db2.db2.importCoreDb(db2.tx2, adb, info, stopOnError)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
