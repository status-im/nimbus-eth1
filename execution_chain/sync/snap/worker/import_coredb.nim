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
  std/paths,
  pkg/chronicles,
  ./import_coredb/[coredb_desc, coredb_import, coredb_stats],
  ./[helpers, cache_db, worker_desc]

export
  coredb_desc,
  coredb_stats

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc importCoreDb*(
    ctx: SnapCtxRef;
    info: static[string];
      ): Opt[Path] =
  ## Import the flat tables into a version of CoreDb/Aristo, different from
  ## the active one. If successful, the installation path is returned.
  ##
  let
    adb = ctx.pool.cacheDB
    status = ?adb.getAccMissingIntv(info)
    header = ?adb.getHeader(status.number, info)

    tx2 = CoreDb2Ref.init(ctx, clean=true)          # open, clear left overs
    txStateRoot = ?tx2.fetchStateRoot(info)         # import data
    db2Dir = tx2.dbDir
  defer: tx2.destroy()

  if header.stateRoot != txStateRoot:
    let txStats = ?tx2.importFlat(adb, info)
    error info & ": Oops, state roots differ", number=status.number,
      stateRoot=header.stateRoot.toStr, expected=txStateRoot.toStr, txStats
    return err()

  ok(db2Dir)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
