# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/sequtils,
  eth/common,
  rocksdb,
  results,
  ../../aristo,
  ../../aristo/aristo_init/rocks_db as use_ari,
  ../../aristo/[aristo_desc, aristo_walk/persistent, aristo_tx],
  ../../kvt,
  ../../kvt/kvt_persistent as use_kvt,
  ../../kvt/kvt_init/rocks_db/rdb_init,
  ../base,
  ./aristo_db,
  ./aristo_db/[common_desc, handlers_aristo],
  ../../opts

include ./aristo_db/aristo_replicate

const
  # Expectation messages
  aristoFail = "Aristo/RocksDB init() failed"
  kvtFail = "Kvt/RocksDB init() failed"

# Annotation helper(s)
{.pragma: rlpRaise, gcsafe, raises: [AristoApiRlpError].}

proc toRocksDb*(
    opts: DbOptions
): tuple[dbOpts: DbOptionsRef, cfOpts: ColFamilyOptionsRef] =
  # TODO the configuration options below have not been tuned but are rather
  #      based on gut feeling, guesses and by looking at other clients - it
  #      would make sense to test different settings and combinations once the
  #      data model itself has settled down as their optimal values will depend
  #      on the shape of the data - it'll also be different per column family..

  let tableOpts = defaultTableOptions()
  # This bloom filter helps avoid having to read multiple SST files when looking
  # for a value.
  # A 9.9-bits-per-key ribbon filter takes ~7 bits per key and has a 1% false
  # positive rate which feels like a good enough starting point, though this
  # should be better investigated.
  # https://github.com/facebook/rocksdb/wiki/RocksDB-Bloom-Filter#ribbon-filter
  # https://github.com/facebook/rocksdb/blob/d64eac28d32a025770cba641ea04e697f475cdd6/include/rocksdb/filter_policy.h#L208
  tableOpts.filterPolicy = createRibbonHybrid(9.9)

  if opts.blockCacheSize > 0:
    # Share a single block cache instance between all column families
    tableOpts.blockCache = cacheCreateLRU(opts.blockCacheSize)

  # Single-level indices might cause long stalls due to their large size -
  # two-level indexing allows the first level to be kept in memory at all times
  # while the second level is partitioned resulting in smoother loading
  # https://github.com/facebook/rocksdb/wiki/Partitioned-Index-Filters#how-to-use-it
  tableOpts.indexType = IndexType.twoLevelIndexSearch
  tableOpts.pinTopLevelIndexAndFilter = true
  tableOpts.cacheIndexAndFilterBlocksWithHighPriority = true
  tableOpts.partitionFilters = true # TODO do we need this?

  # This option adds a small hash index to each data block, presumably speeding
  # up Get queries (but again not range queries) - takes up space, apparently
  # a good tradeoff for most workloads
  # https://github.com/facebook/rocksdb/wiki/Data-Block-Hash-Index
  tableOpts.dataBlockIndexType = DataBlockIndexType.binarySearchAndHash
  tableOpts.dataBlockHashRatio = 0.75

  let cfOpts = defaultColFamilyOptions()

  cfOpts.blockBasedTableFactory = tableOpts

  if opts.writeBufferSize > 0:
    cfOpts.writeBufferSize = opts.writeBufferSize

  # When data is written to rocksdb, it is first put in an in-memory table
  # whose index is a skip list. Since the mem table holds the most recent data,
  # all reads must go through this skiplist which results in slow lookups for
  # already-written data.
  # We enable a bloom filter on the mem table to avoid this lookup in the cases
  # where the data is actually on disk already (ie wasn't updated recently).
  # TODO there's also a hashskiplist that has both a hash index and a skip list
  #      which maybe could be used - uses more memory, requires a key prefix
  #      extractor
  cfOpts.memtableWholeKeyFiltering = true
  cfOpts.memtablePrefixBloomSizeRatio = 0.1

  # LZ4 seems to cut database size to 2/3 roughly, at the time of writing
  # Using it for the bottom-most level means it applies to 90% of data but
  # delays compression until data has settled a bit, which seems like a
  # reasonable tradeoff.
  # TODO evaluate zstd compression with a trained dictionary
  # https://github.com/facebook/rocksdb/wiki/Compression
  cfOpts.bottommostCompression = Compression.lz4Compression

  # TODO In the AriVtx table, we don't do lookups that are expected to result
  #      in misses thus we could avoid the filter cost - this does not apply to
  #      other tables since their API admit queries that might result in
  #      not-found - specially the KVT which is exposed to external queries and
  #      the `HashKey` cache (AriKey)
  # https://github.com/EighteenZi/rocksdb_wiki/blob/master/Memory-usage-in-RocksDB.md#indexes-and-filter-blocks
  # https://github.com/facebook/rocksdb/blob/af50823069818fc127438e39fef91d2486d6e76c/include/rocksdb/advanced_options.h#L696
  # cfOpts.optimizeFiltersForHits = true

  cfOpts.maxBytesForLevelBase = cfOpts.writeBufferSize

  # Reduce number of files when the database grows
  cfOpts.targetFileSizeBase = cfOpts.writeBufferSize div 4
  cfOpts.targetFileSizeMultiplier = 4

  let dbOpts = defaultDbOptions()
  dbOpts.maxOpenFiles = opts.maxOpenFiles

  if opts.rowCacheSize > 0:
    # Good for GET queries, which is what we do most of the time - if we start
    # using range queries, we should probably give more attention to the block
    # cache
    # https://github.com/facebook/rocksdb/blob/af50823069818fc127438e39fef91d2486d6e76c/include/rocksdb/options.h#L1276
    dbOpts.rowCache = cacheCreateLRU(opts.rowCacheSize)

  # Without this option, WAL files might never get removed since a small column
  # family (like the admin CF) with only tiny writes might keep it open - this
  # negatively affects startup times since the WAL is replayed on every startup.
  # https://github.com/facebook/rocksdb/blob/af50823069818fc127438e39fef91d2486d6e76c/include/rocksdb/options.h#L719
  # Flushing the oldest
  let writeBufferSize =
    if opts.writeBufferSize > 0:
      opts.writeBufferSize
    else:
      cfOpts.writeBufferSize

  dbOpts.maxTotalWalSize = 2 * writeBufferSize

  dbOpts.keepLogFileNum = 16 # No point keeping 1000 log files around...

  (dbOpts, cfOpts)

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc newAristoRocksDbCoreDbRef*(path: string, opts: DbOptions): CoreDbRef =
  ## This funcion piggybacks the `KVT` on the `Aristo` backend.

  let
    # Sharing opts means we also share caches between column families!
    (dbOpts, cfOpts) = opts.toRocksDb()
    guestCFs = RdbInst.guestCFs(cfOpts)
    (adb, oCfs) = AristoDbRef.init(use_ari.RdbBackendRef, path, dbOpts, cfOpts, guestCFs).valueOr:
      raiseAssert aristoFail & ": " & $error
    kdb = KvtDbRef.init(use_kvt.RdbBackendRef, adb, oCfs).valueOr:
      raiseAssert kvtFail & ": " & $error
  AristoDbRocks.create(kdb, adb)

proc newAristoDualRocksDbCoreDbRef*(path: string, opts: DbOptions): CoreDbRef =
  ## This is only for debugging. The KVT is run on a completely separate
  ## database backend.
  let
    (dbOpts, cfOpts) = opts.toRocksDb()
    (adb, _) = AristoDbRef.init(use_ari.RdbBackendRef, path, dbOpts, cfOpts, []).valueOr:
      raiseAssert aristoFail & ": " & $error
    kdb = KvtDbRef.init(use_kvt.RdbBackendRef, path, dbOpts, cfOpts).valueOr:
      raiseAssert kvtFail & ": " & $error
  AristoDbRocks.create(kdb, adb)

# ------------------------------------------------------------------------------
# Public aristo iterators
# ------------------------------------------------------------------------------

iterator aristoReplicateRdb*(dsc: CoreDbMptRef): (Blob, Blob) {.rlpRaise.} =
  ## Instantiation for `VoidBackendRef`
  for k, v in aristoReplicate[use_ari.RdbBackendRef](dsc):
    yield (k, v)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
