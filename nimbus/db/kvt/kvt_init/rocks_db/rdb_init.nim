# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  std/os,
  rocksdb,
  results,
  ../../kvt_desc,
  ./rdb_desc

const
  extraTraceMessages = false
    ## Enabled additional logging noise

when extraTraceMessages:
  import chronicles

  logScope:
    topics = "kvt-backend"

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    rdb: var RdbInst;
    basePath: string;
    openMax: int;
      ): Result[void,(KvtError,string)] =
  ## Constructor c ode inspired by `RocksStoreRef.init()` from
  ## kvstore_rocksdb.nim
  rdb.basePath = basePath

  let
    dataDir = rdb.dataDir

  try:
    dataDir.createDir
  except OSError, IOError:
    return err((RdbBeCantCreateDataDir, ""))

  let opts = defaultDbOptions()
  opts.setMaxOpenFiles(openMax)

  # Reserve a family corner for `Kvt` on the database
  let baseDb = openRocksDb(dataDir, opts).valueOr:
    let errSym = RdbBeDriverInitError
    when extraTraceMessages:
      debug logTxt "init failed", dataDir, openMax, error=errSym, info=($error)
    return err((errSym, error))

  rdb.store = baseDb
  ok()


proc destroy*(rdb: var RdbInst; flush: bool) =
  ## Destructor (no need to do anything if piggybacked)
  rdb.store.close()

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
