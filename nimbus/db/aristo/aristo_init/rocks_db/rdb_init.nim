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
  ./rdb_desc,
  ../../../opts

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    rdb: var RdbInst;
    basePath: string;
    opts: DbOptions;
      ): Result[void,(AristoError,string)] =
  ## Constructor c ode inspired by `RocksStoreRef.init()` from
  ## kvstore_rocksdb.nim
  const initFailed = "RocksDB/init() failed"

  rdb.basePath = basePath

  let
    dataDir = rdb.dataDir
  try:
    dataDir.createDir
  except OSError, IOError:
    return err((RdbBeCantCreateDataDir, ""))

  let
    cfOpts = defaultColFamilyOptions()

  if opts.writeBufferSize > 0:
    cfOpts.setWriteBufferSize(opts.writeBufferSize)

  let
    cfs = @[initColFamilyDescriptor(AdmCF, cfOpts),
            initColFamilyDescriptor(VtxCF, cfOpts),
            initColFamilyDescriptor(KeyCF, cfOpts)] &
          RdbGuest.mapIt(initColFamilyDescriptor($it, cfOpts))
    dbOpts = defaultDbOptions()

  dbOpts.setMaxOpenFiles(opts.maxOpenFiles)
  dbOpts.setMaxBytesForLevelBase(opts.writeBufferSize)

  if opts.rowCacheSize > 0:
    dbOpts.setRowCache(cacheCreateLRU(opts.rowCacheSize))

  if opts.blockCacheSize > 0:
    let tableOpts = defaultTableOptions()
    tableOpts.setBlockCache(cacheCreateLRU(opts.rowCacheSize))
    dbOpts.setBlockBasedTableFactory(tableOpts)

  # Reserve a family corner for `Aristo` on the database
  let baseDb = openRocksDb(dataDir, dbOpts, columnFamilies=cfs).valueOr:
    raiseAssert initFailed & " cannot create base descriptor: " & error

  # Initialise column handlers (this stores implicitely `baseDb`)
  rdb.admCol = baseDb.withColFamily(AdmCF).valueOr:
    raiseAssert initFailed & " cannot initialise AdmCF descriptor: " & error
  rdb.vtxCol = baseDb.withColFamily(VtxCF).valueOr:
    raiseAssert initFailed & " cannot initialise VtxCF descriptor: " & error
  rdb.keyCol = baseDb.withColFamily(KeyCF).valueOr:
    raiseAssert initFailed & " cannot initialise KeyCF descriptor: " & error

  ok()

proc initGuestDb*(
    rdb: RdbInst;
    instance: int;
      ): Result[RootRef,(AristoError,string)] =
  ## Initialise `Guest` family
  ##
  ## Thus was a worth a try, but there are better solutions and this item
  ## will be removed in future.
  ##
  if high(RdbGuest).ord < instance:
    return err((RdbGuestInstanceUnsupported,""))
  let
    guestSym = $RdbGuest(instance)
    guestDb = rdb.baseDb.withColFamily(guestSym).valueOr:
      raiseAssert "RocksDb/initGuestDb() failed: " & error

  ok RdbGuestDbRef(
    beKind: BackendRocksDB,
    guestDb: guestDb)


proc destroy*(rdb: var RdbInst; flush: bool) =
  ## Destructor
  rdb.baseDb.close()

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
