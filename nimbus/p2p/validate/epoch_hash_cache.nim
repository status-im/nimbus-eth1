# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Hash Cache
## ==========
##
## provide LRU hash, indexed by epoch

import
  ../../utils/lru_cache,
  ethash,
  nimcrypto,
  tables

type
  BlockEpoch = distinct uint64

  EpochHashDigest* = seq[MDigest[512]]
  EpochHashCache* = LruCache[uint64,BlockEpoch,EpochHashDigest,void]

{.push raises: [Defect,CatchableError].}

# ------------------------------------------------------------------------------
# Private cache management functions
# ------------------------------------------------------------------------------

# needed for table key to work
proc `==`(a,b: BlockEpoch): bool {.borrow.}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc initEpochHashCache*(cache: var EpochHashCache; cacheMaxItems = 10) =
  ## Initialise a new cache indexed by block epoch

  template bnToEpoch(num: uint64): BlockEpoch =
    BlockEpoch(blockNumber div EPOCH_LENGTH)

  var toKey: LruKey[uint64,BlockEpoch] =
    proc(blockNumber: uint64): BlockEpoch =
      blockNumber.bnToEpoch

  var toValue: LruValue[uint64,EpochHashDigest,void] =
    proc(blockNumber: uint64): Result[EpochHashDigest,void] =
      let top = blockNumber.bnToEpoch.uint64 * EPOCH_LENGTH
      ok( mkcache( getCacheSize(top), getSeedhash(top)))

  cache.initLruCache(toKey, toValue, cacheMaxItems)


proc getEpochHash*(cache: var EpochHashCache;
                   blockNumber: uint64): auto {.inline.} =
  ## Return hash list, indexed by epoch of argument `blockNumber`
  cache.getLruItem(blockNumber).value

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
