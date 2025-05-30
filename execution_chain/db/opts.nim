# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import results

export results

const
  # https://github.com/facebook/rocksdb/wiki/Setup-Options-and-Basic-Tuning
  defaultMaxOpenFiles* = 2048
  defaultWriteBufferSize* = 64 * 1024 * 1024
  defaultRowCacheSize* = 0
    ## The row cache is disabled by default as the rdb lru caches do a better
    ## job at a similar abstraction level - ie they work at the same granularity
    ## as the rocksdb row cache but with less overhead
  defaultBlockCacheSize* = 1024 * 1024 * 1024 * 2
    ## The block cache is used to cache indicies, ribbon filters and
    ## decompressed data, roughly in that priority order. At the time of writing
    ## we have about 2 giga-entries in the MPT - with the ribbon filter
    ## using about 8 bits per entry we need ~2gb of space just for the filters.
    ##
    ## When the filters don't fit in memory, random access patterns such as
    ## MPT root computations suffer because of filter evictions and subsequent
    ## re-reads from file.
    ##
    ## A bit of space on top of the filter is left for data block caching
  defaultRdbVtxCacheSize* = 512 * 1024 * 1024
    ## Cache of branches and leaves in the state MPTs (world and account)
  defaultRdbKeyCacheSize* = 1280 * 1024 * 1024
    ## Hashes of the above
  defaultRdbBranchCacheSize* = 1024 * 1024 * 1024
    ## Cache of branches and leaves in the state MPTs (world and account)


type DbOptions* = object # Options that are transported to the database layer
  maxOpenFiles*: int
  writeBufferSize*: int
  rowCacheSize*: int
  blockCacheSize*: int
  rdbVtxCacheSize*: int
  rdbKeyCacheSize*: int
  rdbBranchCacheSize*: int
  rdbPrintStats*: bool

func init*(
    T: type DbOptions,
    maxOpenFiles = defaultMaxOpenFiles,
    writeBufferSize = defaultWriteBufferSize,
    rowCacheSize = defaultRowCacheSize,
    blockCacheSize = defaultBlockCacheSize,
    rdbVtxCacheSize = defaultRdbVtxCacheSize,
    rdbKeyCacheSize = defaultRdbKeyCacheSize,
    rdbBranchCacheSize = defaultRdbBranchCacheSize,
    rdbPrintStats = false,
): T =
  T(
    maxOpenFiles: maxOpenFiles,
    writeBufferSize: writeBufferSize,
    rowCacheSize: rowCacheSize,
    blockCacheSize: blockCacheSize,
    rdbVtxCacheSize: rdbVtxCacheSize,
    rdbKeyCacheSize: rdbKeyCacheSize,
    rdbBranchCacheSize: rdbBranchCacheSize,
    rdbPrintStats: rdbPrintStats,
  )
