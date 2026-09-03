# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Not for production.
## -------------------
##
## Module depends on Aristo (maybe in second instance.) This module serves
## as a template how to flush and re-fill production Aristo from the flat
## snap sync tables once they are ready.
##
{.push raises: [].}

import
  std/paths,
  ../../../../db/[aristo, core_db, core_db/persistent, opts],
  ../worker_desc

from ../../../../db/core_db/backend/rocksdb_desc
  import DbFolder

const
  coreDb2Folder = DbFolder & ".new"

type
  AristoImportStats* = tuple
    nAccounts: uint
    nSlots: uint

  CoreDb2Ref* = ref object
    ## Secondary core DB
    tx2*: CoreDbTxRef
    db2: CoreDbRef

# ------------------------------------------------------------------------------
# Public constuctor/destructor
# ------------------------------------------------------------------------------

proc init*(_: type CoreDb2Ref, ctx: SnapCtxRef, clean = false): CoreDb2Ref =
  let
    dbOpts = DbOptions.init()
    dataDir = string(ctx.pool.cacheDB.dir / Path(coreDb2Folder))
  var
    db2 = AristoDbRocks.newCoreDbRef(dataDir, dbOpts)
  if clean:
    db2.close(wipe=true)
    db2 = AristoDbRocks.newCoreDbRef(dataDir, dbOpts)
  CoreDb2Ref(db2: db2, tx2: db2.baseTxFrame)

proc destroy*(db: CoreDb2Ref) =
  db.db2.close()
  db.tx2 = nil
  db.db2 = nil

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc mpt*(db2: CoreDb2Ref): AristoDbRef =
  db2.db2.mpt

proc persist*(db2: CoreDb2Ref) =
  db2.db2.persist(db2.tx2)

proc checkpoint*(db2: CoreDb2Ref, bn: BlockNumber) =
  db2.tx2.checkpoint(bn)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
