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

const
  AdmKey* = default(seq[byte])

  MAX_STO_VERTEX_BLOB_SIZE* = 67
    ## Longest storage trie record once an embedded hash key is stripped - a
    ## storage leaf with a 32-byte value and a 64-nibble path

type
  StoVertexBuf* = ArrayBuf[MAX_STO_VERTEX_BLOB_SIZE, byte]

  RdbTrieLru*[A, S] = object
    ## Read cache split by trie - the account trie part is keyed by the bare
    ## `VertexID` while static vids repeat across storage tries, which are
    ## therefore keyed by `RootedVertexID`
    acc*: ConcurrentLruCache[VertexID, A]
    sto*: ConcurrentLruCache[RootedVertexID, S]
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

    rdKeyLru*: RdbTrieLru[HashKey, HashKey]                         ## Read cache
    rdVtxLru*: RdbTrieLru[VertexBuf, StoVertexBuf]                  ## Read cache
    rdBranchLru*: RdbTrieLru[(VertexID, uint16), (VertexID, uint16)] ## Read cache

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

template isAcc(lru: RdbTrieLru, rvid: RootedVertexID): bool =
  rvid.root == STATE_ROOT_VID and lru.accCapacity > 0

func stripFrom*(buf: var StoVertexBuf, vtxBuf: VertexBuf) {.inline.} =
  let
    start = if (vtxBuf.buf[vtxBuf.len - 1] and 0x80) != 0: 32 else: 0
    len = vtxBuf.len - start
  doAssert len <= MAX_STO_VERTEX_BLOB_SIZE
  copyMem(addr buf.buf[0], addr vtxBuf.buf[start], MAX_STO_VERTEX_BLOB_SIZE)
  buf.n = typeof(buf.n)(len)
  buf.buf[len - 1] = buf.buf[len - 1] and 0x7f

proc init*[A, S](
    lru: var RdbTrieLru[A, S], accCapacity, stoCapacity: int, threadSafe: bool
) =
  lru.accCapacity = accCapacity
  lru.stoCapacity = stoCapacity
  if threadSafe:
    lru.acc.init(accCapacity)
    lru.sto.init(stoCapacity)
  else:
    lru.acc.init(accCapacity, shardBits = 0, threadSafe = false)
    lru.sto.init(stoCapacity, shardBits = 0, threadSafe = false)

proc dispose*[A, S](lru: var RdbTrieLru[A, S]) =
  lru.acc.dispose()
  lru.sto.dispose()
  lru.acc.reset()
  lru.sto.reset()

proc clear*[A, S](lru: var RdbTrieLru[A, S], threadSafe: bool) =
  lru.dispose()
  lru.init(lru.accCapacity, lru.stoCapacity, threadSafe)

func hasRoom*[A, S](lru: var RdbTrieLru[A, S], rvid: RootedVertexID): bool {.inline.} =
  if lru.isAcc(rvid):
    lru.acc.len < lru.acc.capacity
  else:
    lru.sto.len < lru.sto.capacity

func peek*[V](lru: var RdbTrieLru[V, V], rvid: RootedVertexID): Opt[V] {.inline, noinit.} =
  if lru.isAcc(rvid):
    result = lru.acc.peek(rvid.vid)
  else:
    result = lru.sto.peek(rvid)

proc get*[V](lru: var RdbTrieLru[V, V], rvid: RootedVertexID): Opt[V] {.inline, noinit.} =
  if lru.isAcc(rvid):
    result = lru.acc.get(rvid.vid)
  else:
    result = lru.sto.get(rvid)

proc del*[A, S](lru: var RdbTrieLru[A, S], rvid: RootedVertexID) {.inline.} =
  if lru.isAcc(rvid):
    lru.acc.del(rvid.vid)
  else:
    lru.sto.del(rvid)

template put*[A, S](lru: var RdbTrieLru[A, S], rvid: RootedVertexID, val: A) =
  if lru.isAcc(rvid):
    lru.acc.put(rvid.vid, val)
  else:
    when A is S:
      lru.sto.put(rvid, val)
    else:
      var stoVal {.noinit.}: S
      stoVal.stripFrom(val)
      lru.sto.put(rvid, stoVal)

template update*[A, S](lru: var RdbTrieLru[A, S], rvid: RootedVertexID, val: A): bool =
  if lru.isAcc(rvid):
    lru.acc.update(rvid.vid, val)
  else:
    when A is S:
      lru.sto.update(rvid, val)
    else:
      var stoVal {.noinit.}: S
      stoVal.stripFrom(val)
      lru.sto.update(rvid, stoVal)

template withGet*[A, S](
    lru: var RdbTrieLru[A, S], rvid: RootedVertexID, value, body: untyped
) =
  if lru.isAcc(rvid):
    lru.acc.withGet(rvid.vid, value, body)
  else:
    lru.sto.withGet(rvid, value, body)

template withPeek*[A, S](
    lru: var RdbTrieLru[A, S], rvid: RootedVertexID, value, body: untyped
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
