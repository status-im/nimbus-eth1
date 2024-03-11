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
  std/os,
  chronicles,
  rocksdb/lib/librocksdb,
  rocksdb,
  results,
  ../../aristo_desc,
  ./rdb_desc

logScope:
  topics = "aristo-backend"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "RocksDB/init " & info

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
  try:
    rdb.cacheDir.createDir
  except OSError, IOError:
    return err((RdbBeCantCreateTmpDir, ""))

  let dbOpts = defaultDbOptions()
  dbOpts.setMaxOpenFiles(openMax)

  let rc = openRocksDb(dataDir, dbOpts)
  if rc.isErr:
    let error = RdbBeDriverInitError
    debug logTxt "driver failed", dataDir, openMax,
      error, info=rc.error
    return err((RdbBeDriverInitError, rc.error))

  rdb.dbOpts = dbOpts
  rdb.store = rc.get()

  # The following is a default setup (subject to change)
  rdb.impOpt = rocksdb_ingestexternalfileoptions_create()
  rdb.envOpt = rocksdb_envoptions_create()
  ok()


proc destroy*(rdb: var RdbInst; flush: bool) =
  ## Destructor
  rdb.envOpt.rocksdb_envoptions_destroy()
  rdb.impOpt.rocksdb_ingestexternalfileoptions_destroy()
  rdb.store.close()

  try:
    rdb.cacheDir.removeDir

    if flush:
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
