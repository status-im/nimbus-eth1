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
  std/concurrency/atomics,
  stew/endians2,
  eth/keccak/rapidhash,
  ../../../../concurrency/lru,
  ../../../core_db/backend/rocksdb_desc,
  ../../[aristo_blobify, aristo_desc],
  ../init_common


export lru, rocksdb_desc

const AdmKey* = default(seq[byte])

type
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

  RdbCacheKey* = object
    ## `RootedVertexID` packed into 12 bytes at 4-byte alignment so that LRU
    ## nodes carry no padding. Both ids must fit in 48 bits - larger ones
    ## bypass the caches (see `toCacheKey`).
    ##
    ##   data[0]  bits 31..0   vid[31..0]
    ##   data[1]  bits 31..16  root[15..0]
    ##            bits 15..0   vid[47..32]
    ##   data[2]  bits 31..0   root[47..16]
    data: array[3, uint32]

  RdbBranchVal* = object
    ## Cached `BranchRef` payload: the 48-bit `startVid` and the 16-bit `used`
    ## child mask packed into 8 bytes at 4-byte alignment. A `startVid` beyond
    ## 48 bits is cached as a blob in the vertex cache instead.
    ##
    ##   data[0]  bits 31..0   startVid[31..0]
    ##   data[1]  bits 31..16  used[15..0]
    ##            bits 15..0   startVid[47..32]
    data: array[2, uint32]

  RdbInst* = object
    baseDb*: RocksDbInstanceRef
    vtxCol*: ColFamilyReadWrite        ## Vertex column family handler

    # Note that the key type `VertexID` for LRU caches requires that there is
    # strictly no vertex ID re-use.
    #
    # Otherwise, in some fringe cases one might remove a vertex with key
    # `(root1,vid)` and insert another vertex with key `(root2,vid)` while
    # re-using the vertex ID `vid`. Without knowledge of `root1` and `root2`,
    # the LRU cache will return the same vertex for `(root2,vid)` also for
    # `(root1,vid)`.
    #
    # The other alternaive would be to use the key type `RootedVertexID` which
    # is less memory and time efficient (the latter one due to internal LRU
    # handling of the longer key.)
    #
    rdKeyLru*: ConcurrentLruCache[RdbCacheKey,HashKey] ## Read cache
    rdKeySize*: int

    rdVtxLru*: ConcurrentLruCache[RdbCacheKey,VertexBuf] ## Read cache
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

static:
  doAssert sizeof(RdbCacheKey) == 12 and alignof(RdbCacheKey) == 4
  doAssert sizeof(RdbBranchVal) == 8 and alignof(RdbBranchVal) == 4
  doAssert FIRST_DYNAMIC_VID < (1'u64 shl 40)

func toCacheKey*(rvid: RootedVertexID): Opt[RdbCacheKey] {.inline.} =
  let
    root = rvid.root.uint64
    vid = rvid.vid.uint64
  if ((root or vid) shr 48) == 0:
    Opt.some(RdbCacheKey(
      data: [uint32(vid), uint32(vid shr 32) or (uint32(root) shl 16), uint32(root shr 16)]))
  else:
    Opt.none(RdbCacheKey)

func `==`*(a, b: RdbCacheKey): bool {.inline.} =
  a.data[0] == b.data[0] and a.data[1] == b.data[1] and a.data[2] == b.data[2]

func hash*(k: RdbCacheKey): Hash {.inline.} =
  cast[Hash](rapidhashNano(cast[array[16, byte]]([k.data[0], k.data[1], k.data[2], 0'u32])))

func init*(T: type RdbBranchVal, startVid: VertexID, used: uint16): Opt[T] {.inline.} =
  let v = startVid.uint64
  if (v shr 48) == 0:
    Opt.some(T(data: [uint32(v), uint32(v shr 32) or (uint32(used) shl 16)]))
  else:
    Opt.none(T)

func toBranchVal*(vtx: VertexRef): Opt[RdbBranchVal] {.inline.} =
  if vtx.vType == Branch:
    let vtx = BranchRef(vtx)
    RdbBranchVal.init(vtx.startVid, vtx.used)
  else:
    Opt.none(RdbBranchVal)

func startVid*(v: RdbBranchVal): VertexID {.inline.} =
  VertexID(uint64(v.data[0]) or (uint64(v.data[1] and 0xFFFF'u32) shl 32))

func used*(v: RdbBranchVal): uint16 {.inline.} =
  uint16(v.data[1] shr 16)

template toOpenArray*(xid: AdminTabID): openArray[byte] =
  xid.uint64.toBytesBE.toOpenArray(0,7)

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
