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

  let
    cfs = @[initColFamilyDescriptor(AdmCF, cfOpts),
            initColFamilyDescriptor(VtxCF, cfOpts),
            initColFamilyDescriptor(KeyCF, cfOpts)] &
          RdbGuest.mapIt(initColFamilyDescriptor($it, cfOpts))
    dbOpts = defaultDbOptions()

  dbOpts.setMaxOpenFiles(opts.maxOpenFiles)
  dbOpts.setMaxBytesForLevelBase(opts.writeBufferSize)

  if opts.rowCacheSize > 0:
    # Good for GET queries, which is what we do most of the time - if we start
    # using range queries, we should probably give more attention to the block
    # cache
    # https://github.com/facebook/rocksdb/blob/af50823069818fc127438e39fef91d2486d6e76c/include/rocksdb/options.h#L1276
    dbOpts.setRowCache(cacheCreateLRU(opts.rowCacheSize))

  # We mostly look up data we know is there, so we don't need filters at the
  # last level of the database - this option saves 90% bloom filter memory usage
  # TODO verify this point
  # https://github.com/EighteenZi/rocksdb_wiki/blob/master/Memory-usage-in-RocksDB.md#indexes-and-filter-blocks
  # https://github.com/facebook/rocksdb/blob/af50823069818fc127438e39fef91d2486d6e76c/include/rocksdb/advanced_options.h#L696
  dbOpts.setOptimizeFiltersForHits(true)

  let tableOpts = defaultTableOptions()
  # This bloom filter helps avoid having to read multiple SST files when looking
  # for a value.
  # A 9.9-bits-per-key ribbon filter takes ~7 bits per key and has a 1% false
  # positive rate which feels like a good enough starting point, though this
  # should be better investigated.
  # https://github.com/facebook/rocksdb/wiki/RocksDB-Bloom-Filter#ribbon-filter
  # https://github.com/facebook/rocksdb/blob/d64eac28d32a025770cba641ea04e697f475cdd6/include/rocksdb/filter_policy.h#L208
  tableOpts.setFilterPolicy(createRibbonHybrid(9.9))

  if opts.blockCacheSize > 0:
    tableOpts.setBlockCache(cacheCreateLRU(opts.rowCacheSize))

  # Single-level indices might cause long stalls due to their large size -
  # two-level indexing allows the first level to be kept in memory at all times
  # while the second level is partitioned resulting in smoother loading
  # https://github.com/facebook/rocksdb/wiki/Partitioned-Index-Filters#how-to-use-it
  tableOpts.setIndexType(IndexType.twoLevelIndexSearch)
  tableOpts.setPinTopLevelIndexAndFilter(true)
  tableOpts.setCacheIndexAndFilterBlocksWithHighPriority(true)
  tableOpts.setPartitionFilters(true) # TODO do we need this?

  # This option adds a small hash index to each data block, presumably speeding
  # up Get queries (but again not range queries) - takes up space, apparently
  # a good tradeoff for most workloads
  # https://github.com/facebook/rocksdb/wiki/Data-Block-Hash-Index
  tableOpts.setDataBlockIndexType(DataBlockIndexType.binarySearchAndHash)
  tableOpts.setDataBlockHashRatio(0.75)

  dbOpts.setBlockBasedTableFactory(tableOpts)

  # Reserve a family corner for `Aristo` on the database
  let baseDb = openRocksDb(dataDir, dbOpts, columnFamilies = cfs).valueOr:
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
