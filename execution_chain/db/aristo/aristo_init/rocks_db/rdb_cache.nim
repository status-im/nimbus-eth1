# nimbus-eth1
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Rocks DB read cache keys and helpers
## ===================================

{.push raises: [].}

import
  std/hashes,
  ../../../../concurrency/lru,
  ../../[aristo_blobify, aristo_desc]

export lru

const STATIC_CACHE_KIND = 1'u64 shl 63

type
  RdbCacheKey* = distinct uint64
    ## 8-byte LRU key for a `RootedVertexID`, see `cacheKey`

  RdbKeyVal* = tuple[key: HashKey, check: uint32]
  RdbBranchVal* = tuple[startVid: VertexID, used: uint16, check: uint32]

  RdbKeyLru* = ConcurrentLruCache[RdbCacheKey, RdbKeyVal]
  RdbVtxLru* = ConcurrentLruCache[RootedVertexID, VertexBuf]
  RdbBranchLru* = ConcurrentLruCache[RdbCacheKey, RdbBranchVal]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func `==`*(a, b: RdbCacheKey): bool {.borrow.}

func hash*(k: RdbCacheKey): Hash {.inline.} =
  hash(uint64(k))

static: doAssert FIRST_DYNAMIC_VID <= 1'u64 shl 33

func cacheKey*(rvid: RootedVertexID): (RdbCacheKey, uint32) {.inline.} =
  ## 8-byte key and 4-byte check that together identify `rvid` exactly.
  ##
  ## Dynamic vids are globally unique (one `vTop` counter, never re-used), so
  ## they are their own key and the check only verifies the root. Static vids
  ## repeat across storage tries: the key holds `root * FIRST_DYNAMIC_VID + vid`
  ## modulo 2^63, which is injective among roots sharing `root shr 30`, the
  ## check. Bit 63 separates the two kinds. Exact for every root below 2^62.
  let vid = uint64(rvid.vid)
  if vid >= FIRST_DYNAMIC_VID:
    (RdbCacheKey(vid), uint32(rvid.root))
  else:
    # Bit 63 marks a static key; dynamic keys are bare vids below 2^63, so the
    # two kinds never coincide. The arithmetic wraps modulo 2^64 and the `or`
    # overwrites bit 63, so the key carries the sum modulo 2^63.
    #
    # With root = hi * 2^30 + lo and R = FIRST_DYNAMIC_VID:
    #   root * R + vid = hi * 2^30 * R + (lo * R + vid)
    # Modulo 2^63 the first term is a fixed offset shared by every root of the
    # class hi, and lo * R + vid < 2^30 * 2^33 = 2^63 identifies (lo, vid)
    # uniquely (vid < R, so division by R recovers both). Adding a fixed offset
    # modulo 2^63 is a bijection, so within a class different (lo, vid) always
    # give different keys, and hi itself is the check. Below 2^62 the check does
    # not truncate, so key and check together recover (hi, lo, vid).
    let
      root = uint64(rvid.root)
      key = STATIC_CACHE_KIND or (root * FIRST_DYNAMIC_VID + vid)

    (RdbCacheKey(key), uint32(root shr 30))

template withGet*[V](
    lru: var ConcurrentLruCache[RdbCacheKey, V],
    rvid: RootedVertexID,
    value, body: untyped,
) =
  let kc = rvid.cacheKey()
  lru.withGet(kc[0], value):
    if value.check == kc[1]:
      body

template withPeek*[V](
    lru: var ConcurrentLruCache[RdbCacheKey, V],
    rvid: RootedVertexID,
    value, body: untyped,
) =
  let kc = rvid.cacheKey()
  lru.withPeek(kc[0], value):
    if value.check == kc[1]:
      body

template del*[V](lru: var ConcurrentLruCache[RdbCacheKey, V], rvid: RootedVertexID) =
  lru.del(rvid.cacheKey()[0])

template put*(
    lru: var RdbKeyLru,
    rvid: RootedVertexID,
    key: HashKey,
) =
  let
    kc = rvid.cacheKey()
    v: RdbKeyVal = (key, kc[1])
  lru.put(kc[0], v)

template update*(
    lru: var RdbKeyLru,
    rvid: RootedVertexID,
    key: HashKey,
): bool =
  let
    kc = rvid.cacheKey()
    v: RdbKeyVal = (key, kc[1])
  lru.update(kc[0], v)

template put*(
    lru: var RdbBranchLru,
    rvid: RootedVertexID,
    startVid: VertexID,
    used: uint16,
) =
  let
    kc = rvid.cacheKey()
    v: RdbBranchVal = (startVid, used, kc[1])
  lru.put(kc[0], v)

template update*(
    lru: var RdbBranchLru,
    rvid: RootedVertexID,
    startVid: VertexID,
    used: uint16,
): bool =
  let
    kc = rvid.cacheKey()
    v: RdbBranchVal = (startVid, used, kc[1])
  lru.update(kc[0], v)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
