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
  ../../../../concurrency/lru,
  ../../../core_db/backend/rocksdb_desc,
  ../../[aristo_blobify, aristo_desc],
  ../init_common


export lru, rocksdb_desc

const AdmKey* = default(seq[byte])

type
  RdbTrieLru*[V] = object
    ## Read cache split by trie - the account trie part is keyed by the bare
    ## `VertexID` while static vids repeat across storage tries, which are
    ## therefore keyed by `RootedVertexID`
    acc*: ConcurrentLruCache[VertexID, V]
    sto*: ConcurrentLruCache[RootedVertexID, V]
    accCapacity*: int
    stoCapacity*: int

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

    rdKeyLru*: RdbTrieLru[HashKey]               ## Read cache
    rdVtxLru*: RdbTrieLru[VertexBuf]             ## Read cache
    rdBranchLru*: RdbTrieLru[(VertexID, uint16)] ## Read cache

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

template isAcc[V](lru: RdbTrieLru[V], rvid: RootedVertexID): bool =
  rvid.root == STATE_ROOT_VID and lru.accCapacity > 0

proc init*[V](
    lru: var RdbTrieLru[V], accCapacity, stoCapacity: int, threadSafe: bool
) =
  lru.accCapacity = accCapacity
  lru.stoCapacity = stoCapacity
  if threadSafe:
    lru.acc.init(accCapacity)
    lru.sto.init(stoCapacity)
  else:
    lru.acc.init(accCapacity, shardBits = 0, threadSafe = false)
    lru.sto.init(stoCapacity, shardBits = 0, threadSafe = false)

proc dispose*[V](lru: var RdbTrieLru[V]) =
  lru.acc.dispose()
  lru.sto.dispose()
  lru.acc.reset()
  lru.sto.reset()

proc clear*[V](lru: var RdbTrieLru[V], threadSafe: bool) =
  lru.dispose()
  lru.init(lru.accCapacity, lru.stoCapacity, threadSafe)

func hasRoom*[V](lru: var RdbTrieLru[V], rvid: RootedVertexID): bool {.inline.} =
  if lru.isAcc(rvid):
    lru.acc.len < lru.acc.capacity
  else:
    lru.sto.len < lru.sto.capacity

func peek*[V](lru: var RdbTrieLru[V], rvid: RootedVertexID): Opt[V] {.inline, noinit.} =
  if lru.isAcc(rvid):
    result = lru.acc.peek(rvid.vid)
  else:
    result = lru.sto.peek(rvid)

proc get*[V](lru: var RdbTrieLru[V], rvid: RootedVertexID): Opt[V] {.inline, noinit.} =
  if lru.isAcc(rvid):
    result = lru.acc.get(rvid.vid)
  else:
    result = lru.sto.get(rvid)

proc del*[V](lru: var RdbTrieLru[V], rvid: RootedVertexID) {.inline.} =
  if lru.isAcc(rvid):
    lru.acc.del(rvid.vid)
  else:
    lru.sto.del(rvid)

template put*[V](lru: var RdbTrieLru[V], rvid: RootedVertexID, val: V) =
  if lru.isAcc(rvid):
    lru.acc.put(rvid.vid, val)
  else:
    lru.sto.put(rvid, val)

template update*[V](lru: var RdbTrieLru[V], rvid: RootedVertexID, val: V): bool =
  if lru.isAcc(rvid):
    lru.acc.update(rvid.vid, val)
  else:
    lru.sto.update(rvid, val)

template withGet*[V](
    lru: var RdbTrieLru[V], rvid: RootedVertexID, value, body: untyped
) =
  if lru.isAcc(rvid):
    lru.acc.withGet(rvid.vid, value, body)
  else:
    lru.sto.withGet(rvid, value, body)

template withPeek*[V](
    lru: var RdbTrieLru[V], rvid: RootedVertexID, value, body: untyped
) =
  if lru.isAcc(rvid):
    lru.acc.withPeek(rvid.vid, value, body)
  else:
    lru.sto.withPeek(rvid, value, body)

template inc*(v: var RdbLruCounter, hit: bool) =
  discard v[hit].fetchAdd(1, moRelaxed)

template get*(v: RdbLruCounter, hit: bool): uint64 =
  v[hit].load(moRelaxed)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
