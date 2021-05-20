# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Hash as hash can
## ================
##
## provide hash lists, indexed by epoch

import
  ethash,
  nimcrypto,
  tables

type
  EpochHashDigest* = seq[MDigest[512]]

  EpochHashCache* = object
    maxItems: int                              ## max number of entries
    tab: OrderedTable[uint64,EpochHashDigest]  ## cache data table

# ------------------------------------------------------------------------------
# Private cache management functions
# ------------------------------------------------------------------------------

proc mkCacheBytes(blockNumber: uint64): seq[MDigest[512]] {.inline.} =
  mkcache(getCacheSize(blockNumber), getSeedhash(blockNumber))

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc initEpochHashCache*(cache: var EpochHashCache; cacheMaxItems = 10) =
  ## Initialise a new cache indexed by block epoch
  cache.maxItems = cacheMaxItems

  # note: Starting from Nim v0.20, tables are initialized by default and it
  #       is not necessary to call initOrderedTable() function explicitly.


proc getEpochCacheHash*(cache: var EpochHashCache;
                        blockNumber: uint64): EpochHashDigest =
  ## Return hash list, indexed by epoch of argument `blockNumber`
  let epochIndex = blockNumber div EPOCH_LENGTH

  # Get the cache if already generated, marking it as recently used
  if epochIndex in cache.tab:
    let value = cache.tab[epochIndex]
    cache.tab.del(epochIndex)  # pop and append at end
    cache.tab[epochIndex] = value
    return value

  # Limit memory usage for cache
  if cache.maxItems <= cache.tab.len:
    # Delete oldest entry
    for key in cache.tab.keys:
      # Kludge: OrderedTable[] still misses a proper API
      cache.tab.del(key)
      break

  # Simulate requesting mkcache by block number: multiply index by epoch length
  var data = mkCacheBytes(epochIndex * EPOCH_LENGTH)
  cache.tab[epochIndex] = data

  result = system.move(data)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
