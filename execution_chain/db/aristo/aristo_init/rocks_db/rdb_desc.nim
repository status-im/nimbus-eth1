# nimbus-eth1
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Rocks DB internal driver descriptor
## ===================================

{.push raises: [].}

import
  std/[concurrency/atomics, hashes],
  results,
  stew/endians2,
  ../../../../concurrency/lru,
  ../../../core_db/backend/rocksdb_desc,
  ../../[aristo_blobify, aristo_desc],
  ../init_common


export lru, rocksdb_desc

const
  AdmKey* = default(seq[byte])
  STATIC_CACHE_KIND = 1'u64 shl 63

type
  RdbCacheKey* = distinct uint64
    ## 8-byte LRU key for a `RootedVertexID`, see `cacheKey`

  RdbKeyVal* = tuple[key: HashKey, check: uint32]
  RdbBranchVal* = tuple[startVid: VertexID, used: uint16, check: uint32]

  RdbWriteEventCb* =
    proc(session: WriteBatchRef): bool {.gcsafe, raises: [].}
      ## Call back closure function that passes the the write session handle
      ## to a guest peer right after it was opened. The guest may store any
      ## data on its own column family and return `true` if that worked
      ## all right. Then the `Aristo` handler will stor its own columns and
      ## finalise the write session.
      ##
      ## In case of an error when `false` is returned, `Aristo` will abort the
      ## write session and return a session error.

  RdbInst* = object
    baseDb*: RocksDbInstanceRef
    vtxCol*: ColFamilyReadWrite        ## Vertex column family handler

    rdKeyLru*: ConcurrentLruCache[RdbCacheKey, RdbKeyVal] ## Read cache
    rdKeySize*: int

    rdVtxLru*: ConcurrentLruCache[RootedVertexID,VertexBuf] ## Read cache
    rdVtxSize*: int

    rdBranchLru*: ConcurrentLruCache[RdbCacheKey, RdbBranchVal]
    rdBranchSize*: int

    rdbPrintStats*: bool               ## Print statistics on closure
    threadSafeCaches*: bool
      ## Controls whether the LRU caches are initialized for concurrent access

  AristoCFs* = enum
    ## Column family symbols/handles and names used on the database
    VtxCF = "AriVtx"                   ## Vertex column family name

  RdbLruCounter* = array[bool, Atomic[uint64]]

  RdbStateType* = enum
    Account
    World

  RdbVertexType* = enum
    Empty
    Leaf
    Branch
    ExtBranch

var
  # Hit/miss counters for LRU cache - global so as to integrate easily with
  # nim-metrics and `uint64` to ensure that increasing them is fast - collection
  # happens from a separate thread.
  # TODO maybe turn this into more general framework for LRU reporting since
  #      we have lots of caches of this sort
  rdbBranchLruStats*: array[RdbStateType, RdbLruCounter]
  rdbVtxLruStats*: array[RdbStateType, array[RdbVertexType, RdbLruCounter]]
  rdbKeyLruStats*: array[RdbStateType, RdbLruCounter]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template toOpenArray*(xid: AdminTabID): openArray[byte] =
  xid.uint64.toBytesBE.toOpenArray(0,7)

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
    lru: var ConcurrentLruCache[RdbCacheKey, RdbKeyVal],
    rvid: RootedVertexID,
    key: HashKey,
) =
  let
    kc = rvid.cacheKey()
    v: RdbKeyVal = (key, kc[1])
  lru.put(kc[0], v)

template update*(
    lru: var ConcurrentLruCache[RdbCacheKey, RdbKeyVal],
    rvid: RootedVertexID,
    key: HashKey,
): bool =
  let
    kc = rvid.cacheKey()
    v: RdbKeyVal = (key, kc[1])
  lru.update(kc[0], v)

template put*(
    lru: var ConcurrentLruCache[RdbCacheKey, RdbBranchVal],
    rvid: RootedVertexID,
    startVid: VertexID,
    used: uint16,
) =
  let
    kc = rvid.cacheKey()
    v: RdbBranchVal = (startVid, used, kc[1])
  lru.put(kc[0], v)

template update*(
    lru: var ConcurrentLruCache[RdbCacheKey, RdbBranchVal],
    rvid: RootedVertexID,
    startVid: VertexID,
    used: uint16,
): bool =
  let
    kc = rvid.cacheKey()
    v: RdbBranchVal = (startVid, used, kc[1])
  lru.update(kc[0], v)

template to*(v: RootedVertexID, T: type RdbStateType): RdbStateType =
  if v.root == STATE_ROOT_VID: RdbStateType.World else: RdbStateType.Account

template to*(v: VertexType, T: type RdbVertexType): RdbVertexType =
  case v
  of VertexType.AccLeaf, VertexType.StoLeaf: RdbVertexType.Leaf
  of VertexType.Branch: RdbVertexType.Branch
  of VertexType.ExtBranch: RdbVertexType.ExtBranch
  of VertexType.BoundaryNode: raiseAssert "BoundaryNode is stateless-only and never persisted"

template inc*(v: var RdbLruCounter, hit: bool) =
  discard v[hit].fetchAdd(1, moRelaxed)

template get*(v: RdbLruCounter, hit: bool): uint64 =
  v[hit].load(moRelaxed)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
