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
  ../../../core_db/backend/rocksdb_desc,
  ../../[aristo_blobify, aristo_desc],
  ../init_common,
  ./rdb_cache

export rdb_cache, rocksdb_desc

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
    vtxCol*: ColFamilyReadWrite        ## Vertex column family handler

    rdKeyLru*: RdbKeyLru ## Read cache
    rdKeySize*: int

    rdVtxLru*: RdbVtxLru ## Read cache
    rdVtxSize*: int

    rdBranchLru*: RdbBranchLru
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
