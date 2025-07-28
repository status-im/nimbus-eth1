# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[os, sequtils],
  chronicles,
  rocksdb,
  results,
  ../../aristo/aristo_init/[rocks_db as use_ari, persistent],
  ../../kvt/kvt_init/[rocks_db as use_kvt, persistent],
  ./[aristo_db, rocksdb_desc],
  ../../aristo/aristo_compute,
  ../../opts

# TODO the configuration options below have not been tuned but are rather
#      based on gut feeling, guesses and by looking at other clients - it
#      would make sense to test different settings and combinations once the
#      data model itself has settled down as their optimal values will depend
#      on the shape of the data - it'll also be different per column family..

proc toDbOpts*(opts: DbOptions): DbOptionsRef =
  let dbOpts = defaultDbOptions(autoClose = true)
  dbOpts.maxOpenFiles = opts.maxOpenFiles

  # Needed for vector memtable
  dbOpts.allowConcurrentMemtableWrite = false

  if opts.rowCacheSize > 0:
    # Good for GET queries, which is what we do most of the time - however,
    # because we have other similar caches at different abstraction levels in
    # the codebase, this cache ends up being less impactful than the block cache
    # even though it is faster to access.
    # https://github.com/facebook/rocksdb/blob/af50823069818fc127438e39fef91d2486d6e76c/include/rocksdb/options.h#L1276
    dbOpts.rowCache = cacheCreateLRU(opts.rowCacheSize, autoClose = true)

  dbOpts.keepLogFileNum = 16 # No point keeping 1000 log files around...

  # Parallelize L0 -> Ln compaction
  # https://github.com/facebook/rocksdb/wiki/Subcompaction
  dbOpts.maxSubcompactions = dbOpts.maxBackgroundJobs
  dbOpts

proc toCfOpts*(opts: DbOptions, cache: CacheRef, bulk: bool): ColFamilyOptionsRef =
  let tableOpts = defaultTableOptions(autoClose = true)
  # This bloom filter helps avoid having to read multiple SST files when looking
  # for a value.
  # A 9.9-bits-per-key ribbon filter takes ~7 bits per key and has a 1% false
  # positive rate which feels like a good enough starting point, though this
  # should be better investigated.
  # https://github.com/facebook/rocksdb/wiki/RocksDB-Bloom-Filter#ribbon-filter
  # https://github.com/facebook/rocksdb/blob/d64eac28d32a025770cba641ea04e697f475cdd6/include/rocksdb/filter_policy.h#L208
  tableOpts.filterPolicy = createRibbonHybrid(9.9)

  if cache != nil:
    tableOpts.blockCache = cache

  # Single-level indices might cause long stalls due to their large size -
  # two-level indexing allows the first level to be kept in memory at all times
  # while the second level is partitioned resulting in smoother loading
  # https://github.com/facebook/rocksdb/wiki/Partitioned-Index-Filters#how-to-use-it
  tableOpts.indexType = IndexType.twoLevelIndexSearch
  tableOpts.pinTopLevelIndexAndFilter = true
  tableOpts.cacheIndexAndFilterBlocksWithHighPriority = true
  tableOpts.partitionFilters = true # Ribbon filter partitioning

  # This option adds a small hash index to each data block, presumably speeding
  # up Get queries (but again not range queries) - takes up space, apparently
  # a good tradeoff for most workloads
  # https://github.com/facebook/rocksdb/wiki/Data-Block-Hash-Index
  tableOpts.dataBlockIndexType = DataBlockIndexType.binarySearchAndHash
  tableOpts.dataBlockHashRatio = 0.75

  let cfOpts = defaultColFamilyOptions(autoClose = true)

  cfOpts.blockBasedTableFactory = tableOpts

  if opts.writeBufferSize > 0:
    cfOpts.writeBufferSize = opts.writeBufferSize

  # When data is written to rocksdb, it is first put in an in-memory table. The
  # default implementation is a skip list whose overhead is quite significant
  # both when inserting and during lookups - up to 10% CPU time has been
  # observed in it.
  # Depending on whether the database is bulk-written or not, we'll use a vector
  # representation instead.
  if bulk:
    # Bulk-load changes into a vector which immediately is flushed to L0/1 thus
    # avoiding memtable reads completely (our own in-memory caches perform a
    # similar task with less serialization).
    # A downside of this approach is that the memtable *has* to be flushed in the
    # main thread instead of this operation happening in the background - however,
    # the time it takes to flush is less than it takes to build the skip list, so
    # this ends up being a net win regardless.
    cfOpts.setMemtableVectorRep()
  else:
    # Since the mem table holds the most recent data, all reads must go through
    # this skiplist which results in slow lookups for already-written data.
    # We enable a bloom filter on the mem table to avoid this lookup in the cases
    # where the data is actually on disk already (ie wasn't updated recently).
    # TODO there's also a hashskiplist that has both a hash index and a skip list
    #      which maybe could be used - uses more memory, requires a key prefix
    #      extractor
    cfOpts.memtableWholeKeyFiltering = true
    cfOpts.memtablePrefixBloomSizeRatio = 0.1

  # L0 files may overlap, so we want to push them down to L1 quickly so as to
  # not have to read/examine too many files to find data
  cfOpts.level0FileNumCompactionTrigger = 2

  # ZSTD seems to cut database size to 2/3 roughly, at the time of writing
  # Using it for the bottom-most level means it applies to 90% of data but
  # delays compression until data has settled a bit, which seems like a
  # reasonable tradeoff.
  # Compared to LZ4 that was tested earlier, the default ZSTD config results
  # in 10% less space and similar or slightly better performance in some
  # simple tests around mainnet block 14M.
  # TODO evaluate zstd dictionary compression
  # https://github.com/facebook/rocksdb/wiki/Dictionary-Compression
  cfOpts.bottommostCompression = Compression.zstdCompression

  # With the default options, we end up with 512MB at the base level - a
  # multiplier of 16 means that we can fit 128GB in the next two levels - the
  # more levels, the greater the read amplification at an expense of write
  # amplification - given that we _mostly_ read, this feels like a reasonable
  # tradeoff.
  cfOpts.maxBytesForLevelBase = cfOpts.writeBufferSize * 8
  cfOpts.maxBytesForLevelMultiplier = 16

  # Reduce number of files when the database grows
  cfOpts.targetFileSizeBase = cfOpts.writeBufferSize
  cfOpts.targetFileSizeMultiplier = 4

  # We certainly don't want to re-compact historical data over and over
  cfOpts.ttl = 0
  cfOpts.periodicCompactionSeconds = 0

  cfOpts

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc newRocksDbCoreDbRef*(basePath: string, opts: DbOptions): CoreDbRef =
  # Single rocksdb database with separate column families for mpt/kvt

  # The same column family options are used for all column families meaning that
  # the options are a compromise between the various write and access patterns
  # of what's stored in there - there's room for improvement here!

  # Legacy support: adm CF, if it exists
  let
    cache =
      if opts.blockCacheSize > 0:
        # The block cache holds uncompressed data blocks that each contain multiple
        # key-value pairs - it helps in particular when loading sort-adjacent values
        # such as when the storage of each account is prefixed by a value unique to
        # that account - it is best that this cache is large enough to hold a
        # significant portion of the inner trie nodes!
        # This code sets up a single block cache to be shared, a strategy that
        # plausibly can be refined in the future.
        cacheCreateLRU(opts.blockCacheSize, autoClose = true)
      else:
        nil
    dbOpts = opts.toDbOpts()
    acfOpts = opts.toCfOpts(cache, true)
    # The KVT is is not bulk-flushed so we have to use a skiplist memtable for
    # it
    kcfOpts = opts.toCfOpts(cache, false)

    cfDescs =
      @[($AristoCFs.VtxCF, acfOpts)] & KvtCFs.items().toSeq().mapIt(($it, kcfOpts))
    baseDb = RocksDbInstanceRef.open(basePath, dbOpts, cfDescs).expect(
        "Open database from " & basePath
      )

    adb = AristoDbRef.init(opts, baseDb).valueOr:
      raiseAssert "Could not initialize aristo: " & $error
    kdb = KvtDbRef.init(baseDb)

  if opts.rdbKeyCacheSize > 0:
    # Make sure key cache isn't empty
    adb.txRef.computeKeys(STATE_ROOT_VID).isOkOr:
      fatal "Cannot compute root keys", msg = error
      quit(QuitFailure)

  AristoDbRocks.create(kdb, adb)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
