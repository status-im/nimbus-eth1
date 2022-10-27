# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/[algorithm, tables],
  chronicles,
  eth/[common, trie/db],
  ../../../../db/kvstore_rocksdb,
  ../../range_desc,
  "."/[hexary_desc, hexary_error, rocky_bulk_load, snapdb_desc]

{.push raises: [Defect].}

logScope:
  topics = "snap-db"

type
  AccountsGetFn* = proc(key: openArray[byte]): Blob {.gcsafe.}
    ## The `get()` function for the accounts trie

  StorageSlotsGetFn* = proc(acc: NodeKey; key: openArray[byte]): Blob {.gcsafe.}
    ## The `get()` function for the storage trie depends on the current account

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc convertTo(key: RepairKey; T: type NodeKey): T =
  ## Might be lossy, check before use
  discard result.init(key.ByteArray33[1 .. 32])

proc convertTo(key: RepairKey; T: type NodeTag): T =
  ## Might be lossy, check before use
  UInt256.fromBytesBE(key.ByteArray33[1 .. 32]).T

proc toAccountsKey(a: RepairKey): ByteArray32 =
  a.convertTo(NodeKey).toAccountsKey

proc toStorageSlotsKey(a: RepairKey): ByteArray33 =
  a.convertTo(NodeKey).toStorageSlotsKey

# ------------------------------------------------------------------------------
# Public functions: get
# ------------------------------------------------------------------------------

proc persistentAccountsGetFn*(db: TrieDatabaseRef): AccountsGetFn =
  return proc(key: openArray[byte]): Blob =
    var nodeKey: NodeKey
    if nodeKey.init(key):
      return db.get(nodeKey.toAccountsKey.toOpenArray)

proc persistentStorageSlotsGetFn*(db: TrieDatabaseRef): StorageSlotsGetFn =
  return proc(accKey: NodeKey; key: openArray[byte]): Blob =
    var nodeKey: NodeKey
    if nodeKey.init(key):
      return db.get(nodeKey.toStorageSlotsKey.toOpenArray)
      
# ------------------------------------------------------------------------------
# Public functions: store/put
# ------------------------------------------------------------------------------

proc persistentAccountsPut*(
    db: HexaryTreeDbRef;
    base: TrieDatabaseRef
      ): Result[void,HexaryDbError] =
  ## Bulk load using transactional `put()`
  let dbTx = base.beginTransaction
  defer: dbTx.commit

  for (key,value) in db.tab.pairs:
    if not key.isNodeKey:
      let error = UnresolvedRepairNode
      trace "Unresolved node in repair table", error
      return err(error)
    base.put(key.toAccountsKey.toOpenArray, value.convertTo(Blob))
  ok()

proc persistentStorageSlotsPut*(
    db: HexaryTreeDbRef;
    base: TrieDatabaseRef
      ): Result[void,HexaryDbError] =
  ## Bulk load using transactional `put()`
  let dbTx = base.beginTransaction
  defer: dbTx.commit

  for (key,value) in db.tab.pairs:
    if not key.isNodeKey:
      let error = UnresolvedRepairNode
      trace "Unresolved node in repair table", error
      return err(error)
    base.put(key.toStorageSlotsKey.toOpenArray, value.convertTo(Blob))
  ok()


proc persistentAccountsPut*(
    db: HexaryTreeDbRef;
    rocky: RocksStoreRef
      ): Result[void,HexaryDbError]
      {.gcsafe, raises: [Defect,OSError,KeyError].} =
  ## SST based bulk load on `rocksdb`.
  if rocky.isNil:
    return err(NoRocksDbBackend)
  let bulker = RockyBulkLoadRef.init(rocky)
  defer: bulker.destroy()
  if not bulker.begin(RockyBulkCache):
    let error = CannotOpenRocksDbBulkSession
    trace "Rocky hexary session initiation failed",
      error, info=bulker.lastError()
    return err(error)

  #let keyList = toSeq(db.tab.keys)
  #              .filterIt(it.isNodeKey)
  #              .mapIt(it.convertTo(NodeTag))
  #              .sorted(cmp)
  var
    keyList = newSeq[NodeTag](db.tab.len)
    inx = 0
  for repairKey in db.tab.keys:
    if repairKey.isNodeKey:
      keyList[inx] = repairKey.convertTo(NodeTag)
      inx.inc
  if inx < db.tab.len:
    return err(UnresolvedRepairNode)
  keyList.sort(cmp)

  for n,nodeTag in keyList:
    let
      nodeKey = nodeTag.to(NodeKey)
      data = db.tab[nodeKey.to(RepairKey)].convertTo(Blob)
    if not bulker.add(nodeKey.toAccountsKey.toOpenArray, data):
      let error = AddBulkItemFailed
      trace "Rocky hexary bulk load failure",
        n, len=db.tab.len, error, info=bulker.lastError()
      return err(error)

  if bulker.finish().isErr:
    let error = CommitBulkItemsFailed
    trace "Rocky hexary commit failure",
      len=db.tab.len, error, info=bulker.lastError()
    return err(error)
  ok()


proc persistentStorageSlotsPut*(
    db: HexaryTreeDbRef;
    rocky: RocksStoreRef
      ): Result[void,HexaryDbError]
      {.gcsafe, raises: [Defect,OSError,KeyError].} =
  ## SST based bulk load on `rocksdb`.
  if rocky.isNil:
    return err(NoRocksDbBackend)
  let bulker = RockyBulkLoadRef.init(rocky)
  defer: bulker.destroy()
  if not bulker.begin(RockyBulkCache):
    let error = CannotOpenRocksDbBulkSession
    trace "Rocky hexary session initiation failed",
      error, info=bulker.lastError()
    return err(error)

  #let keyList = toSeq(db.tab.keys)
  #              .filterIt(it.isNodeKey)
  #              .mapIt(it.convertTo(NodeTag))
  #              .sorted(cmp)
  var
    keyList = newSeq[NodeTag](db.tab.len)
    inx = 0
  for repairKey in db.tab.keys:
    if repairKey.isNodeKey:
      keyList[inx] = repairKey.convertTo(NodeTag)
      inx.inc
  if inx < db.tab.len:
    return err(UnresolvedRepairNode)
  keyList.sort(cmp)

  for n,nodeTag in keyList:
    let
      nodeKey = nodeTag.to(NodeKey)
      data = db.tab[nodeKey.to(RepairKey)].convertTo(Blob)
    if not bulker.add(nodeKey.toStorageSlotsKey.toOpenArray, data):
      let error = AddBulkItemFailed
      trace "Rocky hexary bulk load failure",
        n, len=db.tab.len, error, info=bulker.lastError()
      return err(error)

  if bulker.finish().isErr:
    let error = CommitBulkItemsFailed
    trace "Rocky hexary commit failure",
      len=db.tab.len, error, info=bulker.lastError()
    return err(error)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

