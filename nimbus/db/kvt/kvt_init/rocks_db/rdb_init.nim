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
  std/[sequtils, os],
  rocksdb,
  results,
  ../../../aristo/aristo_init/persistent,
  ../../../opts,
  ../../kvt_desc,
  ../../kvt_desc/desc_error as kdb,
  ./rdb_desc

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc getCFInitOptions(opts: DbOptions): ColFamilyOptionsRef =
  result = defaultColFamilyOptions()
  if opts.writeBufferSize > 0:
    result.setWriteBufferSize(opts.writeBufferSize)


proc getDbInitOptions(opts: DbOptions): DbOptionsRef =
  result = defaultDbOptions()
  result.setMaxOpenFiles(opts.maxOpenFiles)
  result.setMaxBytesForLevelBase(opts.writeBufferSize)

  if opts.rowCacheSize > 0:
    result.setRowCache(cacheCreateLRU(opts.rowCacheSize))

  if opts.blockCacheSize > 0:
    let tableOpts = defaultTableOptions()
    tableOpts.setBlockCache(cacheCreateLRU(opts.rowCacheSize))
    result.setBlockBasedTableFactory(tableOpts)

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    rdb: var RdbInst;
    basePath: string;
    opts: DbOptions;
      ): Result[void,(KvtError,string)] =
  ## Database backend constructor for stand-alone version
  ##
  const initFailed = "RocksDB/init() failed"

  rdb.basePath = basePath

  let
    dataDir = rdb.dataDir
  try:
    dataDir.createDir
  except OSError, IOError:
    return err((kdb.RdbBeCantCreateDataDir, ""))

  # Expand argument `opts` to rocksdb options
  let (cfOpts, dbOpts) = (opts.getCFInitOptions, opts.getDbInitOptions)
    
  # Column familiy names to allocate when opening the database.
  let cfs = KvtCFs.mapIt(($it).initColFamilyDescriptor cfOpts)

  # Open database for the extended family :)
  let baseDb = openRocksDb(dataDir, dbOpts, columnFamilies=cfs).valueOr:
    raiseAssert initFailed & " cannot create base descriptor: " & error

  # Initialise column handlers (this stores implicitely `baseDb`)
  for col in KvtCFs:
    rdb.store[col] = baseDb.withColFamily($col).valueOr:
      raiseAssert initFailed & " cannot initialise " &
        $col & " descriptor: " & error
  ok()


proc init*(
    rdb: var RdbInst;
    adb: AristoDbRef;
    opts: DbOptions;
      ): Result[void,(KvtError,string)] =
  ## Initalise column handlers piggy-backing on the `Aristo` backend.
  ##
  let
    cfOpts = opts.getCFInitOptions()
    iCfs = KvtCFs.toSeq.mapIt(initColFamilyDescriptor($it, cfOpts))
    oCfs = adb.reinit(iCfs).valueOr:
      return err((RdbBeHostError,$error))

  # Collect column family descriptors (this stores implicitely `baseDb`)
  for n in KvtCFs:
    assert oCfs[n.ord].name != "" # debugging only
    rdb.store[n] = oCfs[n.ord]

  ok()
 

proc destroy*(rdb: var RdbInst; flush: bool) =
  ## Destructor (no need to do anything if piggybacked)
  if 0 < rdb.basePath.len:
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
