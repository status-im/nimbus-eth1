# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
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
  chronicles,
  rocksdb,
  results,
  ../../kvt_desc,
  ./rdb_desc

logScope:
  topics = "kvt-backend"

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
      ): Result[void,(KvtError,string)] =
  ## Constructor c ode inspired by `RocksStoreRef.init()` from
  ## kvstore_rocksdb.nim
  let
    dataDir = basePath / BaseFolder / DataFolder
    backupsDir = basePath /  BaseFolder / BackupFolder
    tmpDir = basePath /  BaseFolder / TempFolder

  try:
    dataDir.createDir
  except OSError, IOError:
    return err((RdbBeCantCreateDataDir, ""))
  try:
    backupsDir.createDir
  except OSError, IOError:
    return err((RdbBeCantCreateBackupDir, ""))
  try:
    tmpDir.createDir
  except OSError, IOError:
    return err((RdbBeCantCreateTmpDir, ""))

  let rc = rdb.store.init(
    dbPath=dataDir, dbBackuppath=backupsDir, readOnly=false,
    maxOpenFiles=openMax)
  if rc.isErr:
    let error = RdbBeDriverInitError
    debug logTxt "driver failed", dataDir, backupsDir, openMax,
      error, info=rc.error
    return err((RdbBeDriverInitError, rc.error))

  # The following is a default setup (subject to change)
  rdb.impOpt = rocksdb_ingestexternalfileoptions_create()
  rdb.envOpt = rocksdb_envoptions_create()

  rdb.basePath = basePath
  ok()


proc destroy*(rdb: var RdbInst; flush: bool) =
  ## Destructor
  rdb.envOpt.rocksdb_envoptions_destroy()
  rdb.impOpt.rocksdb_ingestexternalfileoptions_destroy()
  rdb.store.close()

  let
    base = rdb.basePath / BaseFolder
  try:
    (base / TempFolder).removeDir

    if flush:
      (base / DataFolder).removeDir

      # Remove the base folder if it is empty
      block done:
        for w in base.walkDirRec:
          # Ignore backup files
          if 0 < w.len and w[^1] != '~':
            break done
        base.removeDir

  except CatchableError:
    discard

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
