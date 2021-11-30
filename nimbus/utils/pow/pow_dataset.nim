# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## LRU Cache for Epoch Indexed Hashimoto Dataset
## =============================================
##
## This module uses the eth-block number (mapped to epoch) to hold and re-use
## the dataset needed for running the `hasimotoFull()` proof-of-work function.

import
  std/[options],
  ./pow_cache,
  eth/common,
  ethash,
  nimcrypto,
  stew/keyed_queue

{.push raises: [Defect].}

type
  PowDatasetItemRef* = ref object
    size*: uint64
    data*: seq[MDigest[512]]

  PowDatasetStats* = tuple
    maxItems: int
    size: int

  PowDataset* = object
    datasetMax: int
    dataset: KeyedQueue[uint64,PowDatasetItemRef]
    cache: PowCacheRef

  PowDatasetRef* = ref PowDataset

const
  nItemsMax = 2
  nItemsInit = 2

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc toKey(bn: BlockNumber): uint64 =
  bn.truncate(uint64) div EPOCH_LENGTH

proc init(pd: var PowDataset;
          maxItems: Option[int]; cache: Option[PowCacheRef]) =
  ## Constructor for LRU cache
  pd.dataset.init(nItemsInit)

  if maxItems.isSome:
    pd.datasetMax = maxItems.get
  else:
    pd.datasetMax = nItemsMax

  if cache.isSome:
    pd.cache = cache.get
  else:
    pd.cache = PowCacheRef.new(nItemsInit)

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(pd: var PowDataset; maxItems = nItemsMax; cache: PowCacheRef) =
  ## Constructor for PoW dataset
  pd.init(some(maxItems), some(cache))

proc init*(pd: var PowDataset; maxItems = nItemsMax) =
  ## Constructor variant
  pd.init(some(maxItems), none(PowCacheRef))


proc init*(T: type PowDataset; maxItems = nItemsMax; cache: PowCacheRef): T =
  ## Constructor variant
  result.init(some(maxItems), some(cache))

proc init*(T: type PowDataset; maxItems = nItemsMax): T =
  ## Constructor variant
  result.init(some(maxItems), none(PowCacheRef))


proc new*(T: type PowDatasetRef; maxItems = nItemsMax; cache: PowCacheRef): T =
  ## Constructor variant
  new result
  result[].init(some(maxItems), some(cache))

proc new*(T: type PowDatasetRef; maxItems = nItemsMax): T =
  ## Constructor for  PoW dataset reference
  new result
  result[].init(some(maxItems), none(PowCacheRef))

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc get*(pd: var PowDataset; bn: BlockNumber): PowDatasetItemRef
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Return a cache derived from argument `blockNumber` ready to be used
  ## for the `hashimotoLight()` method.
  let
    key = bn.toKey
    rc = pd.dataset.lruFetch(key)

  if rc.isOK:
    return rc.value

  let
    # note that `getDataSize()` and `getCacheSize()` depend on
    # `key * EPOCH_LENGTH` rather than the original block number.
    top = key * EPOCH_LENGTH
    cache = pd.cache.get(bn)
    pair = PowDatasetItemRef(
      size: cache.size,
      data: cache.size.calcDataset(cache.data))

  pd.dataset.lruAppend(key, pair, pd.datasetMax)

proc get*(pdr: PowDatasetRef; bn: BlockNumber): PowDatasetItemRef
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Variant of `getCache()`
  pdr[].get(bn)


proc hasItem*(pd: var PowDataset; bn: BlockNumber): bool
    {.gcsafe,raises: [Defect,CatchableError].} =
  ##Returns true if there is a cache entry for argument `bn`.
  pd.dataset.hasKey(bn.toKey)

proc hasItem*(pdr: PowDatasetRef; bn: BlockNumber): bool
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Variant of `hasItem()`
  pdr[].hasItem(bn)

# -------------------------

proc stats*(pd: var PowDataset): PowDatasetStats =
  ## Return current cache sizes
  result = (maxItems: pd.datasetMax, size: pd.dataset.len)

proc stats*(pd: PowDatasetRef): PowDatasetStats =
  ## Variant of `stats()`
  pd[].stats

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
