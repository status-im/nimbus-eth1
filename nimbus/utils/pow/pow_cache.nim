# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## LRU Cache for Epoch Indexed Hashimoto Cache
## ============================================
##
## This module uses the eth-block number (mapped to epoch) to hold and re-use
## the cache needed for running the `hasimotoLight()` proof-of-work function.

import
  eth/common,
  ethash,
  nimcrypto,
  stew/keyed_queue

{.push raises: [Defect].}

type
  PowCacheItemRef* = ref object
    size*: uint64
    data*: seq[MDigest[512]]

  PowCacheStats* = tuple
    maxItems: int
    size: int

  PowCache* = object
    cacheMax: int
    cache: KeyedQueue[uint64,PowCacheItemRef]

  PowCacheRef* = ref PowCache

const
  nItemsMax = 10
  nItemsInit = 2

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc toKey(bn: BlockNumber): uint64 =
  bn.truncate(uint64) div EPOCH_LENGTH

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(pc: var PowCache; maxItems = nItemsMax) =
  ## Constructor for PoW cache
  pc.cacheMax = maxItems
  pc.cache.init(nItemsInit)

proc init*(T: type PowCache; maxItems = nItemsMax): T =
  ## Constructor variant
  result.init(maxItems)

proc new*(T: type PowCacheRef; maxItems = nItemsMax): T =
  ## Constructor variant
  new result
  result[].init(maxItems)

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc get*(pc: var PowCache; bn: BlockNumber): PowCacheItemRef
    {.gcsafe, raises: [Defect, CatchableError].} =
  ## Return a cache derived from argument `blockNumber` ready to be used
  ## for the `hashimotoLight()` method.
  let
    key = bn.toKey
    rc = pc.cache.lruFetch(key)

  if rc.isOK:
    return rc.value

  let
    # note that `getDataSize()` and `getCacheSize()` depend on
    # `key * EPOCH_LENGTH` rather than the original block number.
    top = key * EPOCH_LENGTH
    pair = PowCacheItemRef(
      size: top.getDataSize,
      data: top.getCacheSize.mkcache(top.getSeedhash))

  pc.cache.lruAppend(key, pair, pc.cacheMax)

proc get*(pcr: PowCacheRef; bn: BlockNumber): PowCacheItemRef
    {.gcsafe, raises: [Defect, CatchableError].} =
  ## Variant of `getCache()`
  pcr[].get(bn)

proc hasItem*(pc: var PowCache; bn: BlockNumber): bool
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Returns true if there is a cache entry for argument `bn`.
  pc.cache.hasKey(bn.toKey)

proc hasItem*(pcr: PowCacheRef; bn: BlockNumber): bool
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Variant of `hasItem()`
  pcr[].hasItem(bn)

# -------------------------

proc stats*(pc: var PowCache): PowCacheStats =
  ## Return current cache sizes
  result = (maxItems: pc.cacheMax, size: pc.cache.len)

proc stats*(pcr: PowCacheRef): PowCacheStats =
  ## Variant of `stats()`
  pcr[].stats

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
