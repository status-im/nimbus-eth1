# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  std/os,
  std/concurrency/atomics,
  stew/endians2,
  ../../../core_db/backend/rocksdb_desc,
  ../../aristo_desc,
  ../init_common,
  minilru

export minilru, rocksdb_desc

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

  RdbInst* = object
    baseDb*: RocksDbInstanceRef
    admCol*: ColFamilyReadWrite        ## Legacy column family for administrative data
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
    rdKeyLru*: LruCache[VertexID,HashKey] ## Read cache
    rdKeySize*: int
    rdVtxLru*: LruCache[VertexID,VertexRef] ## Read cache
    rdVtxSize*: int

    rdBranchLru*: LruCache[VertexID, (VertexID, uint16)]
    rdBranchSize*: int

  AristoCFs* = enum
    ## Column family symbols/handles and names used on the database
    AdmCF = "AriAdm"                   ## Admin column family name (deprecated)
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

template to*(v: RootedVertexID, T: type RdbStateType): RdbStateType =
  if v.root == STATE_ROOT_VID: RdbStateType.World else: RdbStateType.Account

template to*(v: VertexType, T: type RdbVertexType): RdbVertexType =
  case v
  of VertexType.AccLeaf, VertexType.StoLeaf: RdbVertexType.Leaf
  of VertexType.Branch: RdbVertexType.Branch
  of VertexType.ExtBranch: RdbVertexType.ExtBranch

template inc*(v: var RdbLruCounter, hit: bool) =
  discard v[hit].fetchAdd(1, moRelaxed)

template get*(v: RdbLruCounter, hit: bool): uint64 =
  v[hit].load(moRelaxed)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
