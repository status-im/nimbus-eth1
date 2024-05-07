# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Rocksdb constructor/destructor for Aristo DB
## ============================================

{.push raises: [].}

import
  std/[sequtils, os],
  rocksdb,
  results,
  ../../aristo_desc,
  ./rdb_desc

const
  extraTraceMessages = false
    ## Enable additional logging noise

when extraTraceMessages:
  import
    chronicles

  logScope:
    topics = "aristo-rocksdb"

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    rdb: var RdbInst;
    basePath: string;
    openMax: int;
      ): Result[void,(AristoError,string)] =
  ## Constructor c ode inspired by `RocksStoreRef.init()` from
  ## kvstore_rocksdb.nim
  rdb.basePath = basePath

  let
    dataDir = rdb.dataDir

  try:
    dataDir.createDir
  except OSError, IOError:
    return err((RdbBeCantCreateDataDir, ""))

  let
    cfs = @[initColFamilyDescriptor AristoFamily] &
          RdbGuest.mapIt(initColFamilyDescriptor $it)
    opts = defaultDbOptions()
  opts.setMaxOpenFiles(openMax)

  # Reserve a family corner for `Aristo` on the database
  let baseDb = openRocksDb(dataDir, opts, columnFamilies=cfs).valueOr:
    let errSym = RdbBeDriverInitError
    when extraTraceMessages:
      trace logTxt "init failed", dataDir, openMax, error=errSym, info=error
    return err((errSym, error))

  # Initialise `Aristo` family
  rdb.store = baseDb.withColFamily(AristoFamily).valueOr:
    let errSym = RdbBeDriverInitError
    when extraTraceMessages:
      trace logTxt "init failed", dataDir, openMax, error=errSym, info=error
    return err((errSym, error))

  ok()

proc initGuestDb*(
    rdb: RdbInst;
    instance: int;
      ): Result[RootRef,(AristoError,string)] =
  # Initialise `Guest` family
  if high(RdbGuest).ord < instance:
    return err((RdbGuestInstanceUnsupported,""))
  let
    guestSym = $RdbGuest(instance)
    guestDb = rdb.store.db.withColFamily(guestSym).valueOr:
      let errSym = RdbBeDriverGuestError
      when extraTraceMessages:
        trace logTxt "guestDb failed", error=errSym, info=error
      return err((errSym, error))

  ok RdbGuestDbRef(
    beKind: BackendRocksDB,
    guestDb: guestDb)


proc destroy*(rdb: var RdbInst; flush: bool) =
  ## Destructor
  rdb.store.db.close()

  if flush:
    try:
      rdb.dataDir.removeDir

      # Remove the base folder if it is empty
      block done:
        for w in rdb.baseDir.walkDirRec:
          # Ignore backup files
          if 0 < w.len and w[^1] != '~':
            break done
        rdb.baseDir.removeDir

    except CatchableError:
      discard

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
