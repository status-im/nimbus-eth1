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
 # TODO the configuration options below have not been tuned but are rather
  #      based on gut feeling, guesses and by looking at other clients - it
  #      would make sense to test different settings and combinations once the
  #      data model itself has settled down as their optimal values will depend
  #      on the shape of the data - it'll also be different per column family..
  let cfOpts = defaultColFamilyOptions()

  if opts.writeBufferSize > 0:
    cfOpts.setWriteBufferSize(opts.writeBufferSize)

  # Without this option, the WAL might never get flushed since a small column
  # family (like the admin CF) with only tiny writes might keep it open - this
  # negatively affects startup times since the WAL is replayed on every startup.
  # https://github.com/facebook/rocksdb/blob/af50823069818fc127438e39fef91d2486d6e76c/include/rocksdb/options.h#L719
  # Flushing the oldest
  let writeBufferSize =
    if opts.writeBufferSize > 0:
      opts.writeBufferSize
    else:
      64 * 1024 * 1024 # TODO read from rocksdb?

  cfOpts.setMaxTotalWalSize(2 * writeBufferSize)

  # When data is written to rocksdb, it is first put in an in-memory table
  # whose index is a skip list. Since the mem table holds the most recent data,
  # all reads must go through this skiplist which results in slow lookups for
  # already-written data.
  # We enable a bloom filter on the mem table to avoid this lookup in the cases
  # where the data is actually on disk already (ie wasn't updated recently).
  # TODO there's also a hashskiplist that has both a hash index and a skip list
  #      which maybe could be used - uses more memory, requires a key prefix
  #      extractor
  cfOpts.setMemtableWholeKeyFiltering(true)
  cfOpts.setMemtablePrefixBloomSizeRatio(0.1)

  # LZ4 seems to cut database size to 2/3 roughly, at the time of writing
  # Using it for the bottom-most level means it applies to 90% of data but
  # delays compression until data has settled a bit, which seems like a
  # reasonable tradeoff.
  # TODO evaluate zstd compression with a trained dictionary
  # https://github.com/facebook/rocksdb/wiki/Compression
  cfOpts.setBottommostCompression(Compression.lz4Compression)

  cfOpts


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
